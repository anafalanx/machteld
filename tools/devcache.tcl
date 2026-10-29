# Content-addressed development stages. This file is sourceable by tests and
# has no compiler/bootstrap side effects. Records are inert Tcl dicts, never
# sourced. Missing, legacy, damaged or mismatched records are cache misses.
#
# It runs on the build runtime, dist/0.21/machteld.exe, as tools/dev.tcl does.
# The runtime's own commands do what the PowerShell helpers did for it on
# tclsh (dev-hash.ps1, toolchain-fingerprint.ps1 and publish-output.ps1):
# `hash` reads files for SHA-256, `links` finds reparse points, `Publish`
# replaces an output in one operation, and `mtps` tells whether a lock's
# holder still runs. No process is started beside the build for this.
namespace eval ::machteld::devcache {
    variable directory [file dirname [file normalize [info script]]]
    # The locks this process holds: normalized path -> the holder it wrote.
    variable locks {}
    # Publication attempts, 500 ms apart: 20 s outlasts the virus scanner's
    # hold on a file just written, as tools/bootstrap.tcl's renames do.
    variable publishAttempts 40
}

# ---- content digests: SHA-256 of bytes, never of times ----

proc ::machteld::devcache::text_digest {text} {
    return [::machteld::hash sum sha256 [encoding convertto utf-8 $text]]
}

# A cache input is a plain file or directory. A symbolic link or junction
# reads as `link` and is refused, so a digest never describes the contents of
# somewhere else; trees are also surveyed with `links`, which reports every
# reparse point below them.
proc ::machteld::devcache::plain {path} {
    if {![catch {file lstat $path stat}] && $stat(type) eq "link"} {
        error "cache input must not be a reparse point: $path"
    }
}

proc ::machteld::devcache::no_reparse_below {root} {
    set survey [::machteld::links $root]
    if {[llength [dict get $survey links]]} {
        error "cache input must not be a reparse point: [dict get [lindex [dict get $survey links] 0] path]"
    }
    if {[llength [dict get $survey errors]]} {
        error "cache input tree is not completely readable: $root"
    }
}

# "missing" for an absent path or a directory, as the PowerShell helper said.
proc ::machteld::devcache::file_digest {path} {
    if {[catch {file lstat $path stat}]} { return missing }
    switch -- $stat(type) {
        file { return [::machteld::hash file sha256 $path] }
        link { error "cache input must not be a reparse point: $path" }
        default { return missing }
    }
}

# The names in one directory, hidden ones included, in code point order.
proc ::machteld::devcache::entries {directory} {
    set names {}
    foreach name [concat [glob -nocomplain -tails -directory $directory *] \
            [glob -nocomplain -tails -types hidden -directory $directory *]] {
        if {$name in {. ..}} continue
        dict set names $name 1
    }
    return [lsort [dict keys $names]]
}

proc ::machteld::devcache::walk {root relative materialVar} {
    upvar 1 $materialVar material
    set directory [expr {$relative eq "" ? $root : [file join $root $relative]}]
    plain $directory
    foreach entry [entries $directory] {
        set name [expr {$relative eq "" ? $entry : "$relative/$entry"}]
        set path [file join $root $name]
        plain $path
        if {[file isdirectory $path]} {
            append material D\0$name\0
            walk $root $name material
        } else {
            append material F\0$name\0[file_digest $path]\0
        }
    }
}

# A directory inventory: every name (hidden files and empty directories too)
# and every file's bytes, so additions, removals and renames all change it.
proc ::machteld::devcache::tree_digest {path} {
    if {[catch {file lstat $path stat}]} { return missing }
    if {$stat(type) eq "link"} { error "cache input must not be a reparse point: $path" }
    if {$stat(type) ne "directory"} { return missing }
    no_reparse_below $path
    set material {}
    walk $path "" material
    return [text_digest $material]
}

# The files directly in one directory that match a pattern, with their bytes.
proc ::machteld::devcache::files_material {root relative pattern} {
    set directory [file join $root {*}[split $relative /]]
    set material $relative\0$pattern\0
    if {[catch {file lstat $directory stat}] || $stat(type) ni {directory link}} {
        return ${material}missing\0
    }
    plain $directory
    set names {}
    foreach name [concat [glob -nocomplain -tails -types f -directory $directory $pattern] \
            [glob -nocomplain -tails -types {f hidden} -directory $directory $pattern]] {
        dict set names $name 1
    }
    foreach name [lsort [dict keys $names]] {
        append material $name\0[file_digest [file join $directory $name]]\0
    }
    return $material
}

# A byte-level identity of the effective C toolchain, never its mtimes: C
# headers, compiler support, target utilities, the CRT and import/static
# libraries (not the unrelated Python, Tcl and the like nested in ucrt64/lib),
# the DLLs beside the compiler, and the executables the build runs. The Tcl
# translation of toolchain-fingerprint.ps1's Toolchain; its material differs
# in form only, so a key the PowerShell helper made simply misses once.
proc ::machteld::devcache::toolchain_digest {root} {
    set root [file normalize $root]
    set material machteld-toolchain-v1\0$root\0
    foreach part {ucrt64/include ucrt64/lib/gcc ucrt64/libexec/gcc ucrt64/x86_64-w64-mingw32 usr/bin} {
        append material $part\0[tree_digest [file join $root {*}[split $part /]]]\0
    }
    append material [files_material $root ucrt64/lib *]
    append material [files_material $root ucrt64/bin *.dll]
    foreach name {gcc cpp as ld ar ranlib strip windres mingw32-make} {
        append material $name\0[file_digest [file join $root ucrt64 bin $name.exe]]\0
    }
    return [text_digest $material]
}

# ---- the build lock ----

# The lock is a file made exclusively that names its holder's process ID and
# start time. machteld 0.21 offers no lock that Windows releases when its
# holder ends, so a lock whose holder no longer runs (or whose ID now belongs
# to another process) is stale and is taken over. A held lock is refused at
# once: two builds never share one development cache.
proc ::machteld::devcache::lock {path} {
    variable locks
    set path [file normalize $path]
    if {[dict exists $locks $path]} { error "lock is already held by this process: $path" }
    set me "[pid] [dict get [::machteld::mtps info [pid]] started]"
    file mkdir [file dirname $path]
    for {set attempt 0} {$attempt < 3} {incr attempt} {
        if {![catch {open $path {WRONLY CREAT EXCL}} channel options]} {
            try { puts -nonewline $channel $me } finally { close $channel }
            dict set locks $path $me
            return locked
        }
        if {[lrange [dict get $options -errorcode] 0 1] ne {POSIX EEXIST}} {
            return -options $options $channel
        }
        if {![stale $path]} { error "lock is held by a running process: $path" }
        catch {file delete $path}
    }
    error "cannot take over the stale lock: $path"
}

# Whether the lock file's holder has gone. A file just made and not yet
# written names nobody for a moment; only an old one that names nobody is stale.
proc ::machteld::devcache::stale {path} {
    if {[catch {
        set channel [open $path rb]
        try { set holder [read $channel 256] } finally { close $channel }
    }]} { return 0 }
    if {[catch {llength $holder} words] || $words != 2} {
        return [expr {[catch {file mtime $path} when] == 0 && [clock seconds] - $when > 10}]
    }
    lassign $holder id started
    if {[catch {::machteld::mtps info $id} row]} { return 1 }
    return [expr {[dict get $row started] ne $started}]
}

# Releases a lock this process holds; the file goes only while it still names
# this holder.
proc ::machteld::devcache::unlock {path} {
    variable locks
    set path [file normalize $path]
    if {![dict exists $locks $path]} { error "lock is not held by this process: $path" }
    set me [dict get $locks $path]
    dict unset locks $path
    if {![catch {
        set channel [open $path rb]
        try { set holder [read $channel 256] } finally { close $channel }
    }] && $holder eq $me} {
        file delete $path
    }
    return unlocked
}

proc ::machteld::devcache::check_tree {path} {
    plain $path
    if {[file isdirectory $path]} {
        foreach name [entries $path] { check_tree [file join $path $name] }
    }
}

# Under the same lock as dev_build, so contention is refused before anything
# is deleted. The whole deletion set is validated first: a reparse point
# anywhere refuses the clean, and none is ever traversed. The lock goes last.
proc ::machteld::devcache::clean {directory} {
    set directory [file normalize $directory]
    if {![file isdirectory $directory]} { return }
    set lockPath [file join $directory build.lock]
    lock $lockPath
    try {
        plain $directory
        no_reparse_below $directory
        set targets {}
        foreach name [entries $directory] {
            set path [file join $directory $name]
            if {$path eq $lockPath} continue
            if {[string first [string trimright $directory /]/ $path] != 0} {
                error "cache clean target escaped its root: $path"
            }
            check_tree $path
            lappend targets $path
        }
        foreach path $targets { file delete -force -- $path }
    } finally { catch {unlock $lockPath} }
}

# ---- fingerprints and records ----

# Every call reads actual bytes; callers may explicitly reuse group digests as
# values within one guarded build. Directory inventories include hidden files,
# names and empty directories, detecting additions, removals and renames.
proc ::machteld::devcache::fingerprint {spec} {
    # Semantic inputs must be re-read at the final publication check too. Their
    # value is already in the key; this guard rejects a changed declaration
    # rather than silently reusing the value captured by reference_spec.
    if {[dict exists $spec runtime_version_guard]} {
        lassign [dict get $spec runtime_version_guard] root expected
        if {[reference_version $root] ne $expected} { error "runtime version changed during reference generation" }
    }
    set material [list machteld-devcache-v1]
    foreach field {values files trees} {
        set items [expr {[dict exists $spec $field] ? [dict get $spec $field] : {}}]
        if {$field eq "values"} {
            lappend material values $items
        } else {
            lappend material $field
            foreach path [lsort -unique $items] {
                set path [file normalize $path]
                lappend material $path [expr {$field eq "files" ? [file_digest $path] : [tree_digest $path]}]
            }
        }
    }
    return [text_digest $material]
}

proc ::machteld::devcache::verify_guard {key specPrefix} {
    if {$key ne [fingerprint [{*}$specPrefix]]} {
        error "development inputs changed during build; previous executable preserved"
    }
}

proc ::machteld::devcache::output_spec {outputs} {
    set spec [dict create files {} trees {}]
    foreach path $outputs {
        dict lappend spec [expr {[file isdirectory $path] ? "trees" : "files"}] $path
    }
    return $spec
}

proc ::machteld::devcache::read_record {path} {
    if {![file isfile $path]} { return {} }
    if {[file size $path] > 1048576} { return {} }
    set ch [open $path r]
    fconfigure $ch -encoding utf-8 -translation lf
    try { set value [read $ch] } finally { close $ch }
    if {[catch {
        if {[llength $value] != 8 || [lsort [dict keys $value]] ne {input output outputs schema} || [dict get $value schema] ne "1"} { return {} }
        foreach field {input output} {
            if {![regexp {^[0-9a-f]{64}$} [dict get $value $field]]} { return {} }
        }
        if {[llength [dict get $value outputs]] == 0} { return {} }
    }]} { return {} }
    return $value
}

proc ::machteld::devcache::current {path key outputs} {
    if {[catch {
        set data [read_record $path]
        if {[dict get $data input] ne $key || [dict get $data outputs] ne $outputs} { return 0 }
        foreach output $outputs { if {![file exists $output]} { return 0 } }
        expr {[dict get $data output] eq [fingerprint [output_spec $outputs]]}
    } result]} { return 0 }
    return $result
}

proc ::machteld::devcache::unique_id {} {
    return [binary encode hex [::machteld::hash random 16]]
}

proc ::machteld::devcache::candidate {output} {
    set parent [file dirname [file normalize $output]]
    file mkdir $parent
    while 1 {
        set path [file join $parent .machteld-build-[unique_id].exe]
        if {![file exists $path]} { return $path }
    }
}

proc ::machteld::devcache::cache_candidate {output} {
    set parent [file dirname [file normalize $output]]
    file mkdir $parent
    while 1 {
        set path [file join $parent .machteld-cache-[unique_id][file extension $output]]
        if {![file exists $path]} { return $path }
    }
}

# ---- publication ----

# One same-directory replacement with the runtime's `Publish`, the primitive
# behind `wrap`: MoveFileExW when the output is absent, ReplaceFileW with a
# backup it deletes or restores when it exists. Either the output name gets
# the complete candidate or both stay as they were; a held output refuses it.
# The candidate must be one of this invocation's own names beside the output.
proc ::machteld::devcache::replace {candidate output pattern} {
    variable publishAttempts
    set candidate [file normalize $candidate]
    set output [file normalize $output]
    if {![string equal -nocase [file dirname $candidate] [file dirname $output]] ||
            [string equal -nocase $candidate $output] ||
            ![regexp $pattern [file tail $candidate]]} {
        error "invalid cache publication pair: $candidate -> $output"
    }
    plain $candidate
    if {[file isdirectory $output]} { error "requested output is a directory: $output" }
    for {set attempt 1} {1} {incr attempt} {
        if {![catch {::machteld::Publish $candidate $output} problem]} { return published }
        if {$attempt >= $publishAttempts} { error "publication failed for $output: $problem" }
        after 500
    }
}

# An executable, as tools/publish-output.ps1 published it.
proc ::machteld::devcache::publish {candidate output} {
    replace $candidate $output {^\.machteld-build-[0-9a-f]{32}\.exe$}
    puts "published [file nativename [file normalize $output]]"
}

# A cache record, object or staged file.
proc ::machteld::devcache::publish_cache {candidate output} {
    replace $candidate $output {^\.machteld-cache-[0-9a-f]{32}}
}

proc ::machteld::devcache::record {path key outputs} {
    foreach output $outputs { if {![file exists $output]} { error "cannot record absent output: $output" } }
    set data [dict create schema 1 input $key outputs $outputs output [fingerprint [output_spec $outputs]]]
    set fresh [cache_candidate $path]
    try {
        set ch [open $fresh {WRONLY CREAT EXCL}]
        fconfigure $ch -encoding utf-8 -translation lf
        try { puts $ch $data } finally { close $ch }
        publish_cache $fresh $path
    } finally { if {[file exists $fresh]} { file delete $fresh } }
}

# commandPrefix is invoked with an ABSENT candidate appended. Publication is
# after successful generation and a second content check of all direct inputs.
proc ::machteld::devcache::ensure {recordPath spec output commandPrefix} {
    set key [fingerprint $spec]
    if {[current $recordPath $key [list $output]]} { return 0 }
    set executable [expr {[string equal -nocase [file extension $output] .exe]}]
    set fresh [expr {$executable ? [candidate $output] : [cache_candidate $output]}]
    try {
        {*}$commandPrefix $fresh
        if {![file isfile $fresh]} { error "development stage produced no output: $fresh" }
        if {$key ne [fingerprint $spec]} { error "development inputs changed during stage; previous output preserved" }
        if {$executable} { publish $fresh $output } else { publish_cache $fresh $output }
        record $recordPath $key [list $output]
    } finally { if {[file exists $fresh]} { file delete $fresh } }
    return 1
}

# Each reference generation owns an immutable fresh directory. Only its small
# record switches on success. A failed generation never deletes a prior pack;
# even completed previous generations remain recoverable until explicit clean.
proc ::machteld::devcache::immutable {recordPath spec parent commandPrefix {force 0}} {
    set key [fingerprint $spec]
    set old [read_record $recordPath]
    if {!$force && [dict exists $old outputs] && [llength [dict get $old outputs]] == 1 &&
            [current $recordPath $key [dict get $old outputs]]} { return [lindex [dict get $old outputs] 0] }
    file mkdir $parent
    set fresh [file join $parent reference-[unique_id]]
    if {[file exists $fresh]} { error "reference candidate already exists: $fresh" }
    {*}$commandPrefix $fresh
    if {![file isdirectory $fresh]} { error "reference generation produced no directory: $fresh" }
    if {$key ne [fingerprint $spec]} { error "reference inputs changed during generation; prior record preserved" }
    record $recordPath $key [list $fresh]
    return $fresh
}

# ---- what each stage reads ----

# The dependency cache is made by tools/bootstrap.tcl from the lock and the
# patches; its state and artifact manifests name what it holds.
proc ::machteld::devcache::dependency_spec {root cache} {
    set files {}
    foreach name {dependencies.lock.json bootstrap.tcl} {
        lappend files [file join $root tools $name]
    }
    lappend files [file join $cache lock.sha256] [file join $cache artifacts.sha256]
    return [dict create files $files trees [list [file join $root tools patches]]]
}

# These variables can introduce files outside the known dependency graph. Do
# not pretend hashing the directory names tracks their contents. Development
# builds use the pinned toolchain and explicit include/library arguments.
proc ::machteld::devcache::compiler_environment {} {
    foreach name {CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH GCC_EXEC_PREFIX COMPILER_PATH
            TCL_LIBRARY TCLLIBPATH TK_LIBRARY CFLAGS CPP CPPFLAGS CXXFLAGS LDFLAGS LIBS ARFLAGS RCFLAGS
            MAKEFLAGS MAKEFILES MAKEOVERRIDES MFLAGS GNUMAKEFLAGS
            BASH_ENV ENV BASHOPTS SHELLOPTS CONFIG_SITE} {
        if {[info exists ::env($name)] && $::env($name) ne ""} {
            error "unset $name for a tracked Machteld build (external compiler/Tcl search paths are not supported)"
        }
    }
    foreach name [array names ::env TCL*_TM_PATH] {
        if {$::env($name) ne ""} { error "unset $name for a tracked Machteld build (external Tcl module paths are not supported)" }
    }
    foreach name [array names ::env BASH_FUNC_*] {
        if {$::env($name) ne ""} { error "unset $name for a tracked Machteld build (exported Bash functions are not supported)" }
    }
    set values {}
    foreach name {PATH SOURCE_DATE_EPOCH MACHTELD_WERROR} {
        if {[info exists ::env($name)]} { lappend values $name $::env($name) }
    }
    return $values
}

# Native subprocesses need only the pinned UCRT tools and Windows itself. An
# inherited PATH can contain per-shell/session launchers which are irrelevant
# to compilation, yet would invalidate every object if fingerprinted as inputs.
# Use this exact PATH both in native keys and around native invocations; keep
# the caller's full environment for Git, the bootstrap check and the guard.
proc ::machteld::devcache::native_environment {msys} {
    set inherited [compiler_environment]
    if {![info exists ::env(SystemRoot)] || $::env(SystemRoot) eq "" ||
            [file pathtype $::env(SystemRoot)] ne "absolute"} {
        error "native development tools require an absolute SystemRoot"
    }
    set windows [file normalize $::env(SystemRoot)]
    set paths {}
    foreach path [list [file join $msys ucrt64 bin] [file join $windows System32] $windows] {
        lappend paths [file nativename [file normalize $path]]
    }
    set values [list PATH [join $paths {;}]]
    foreach name {SOURCE_DATE_EPOCH MACHTELD_WERROR} {
        if {[dict exists $inherited $name]} { lappend values $name [dict get $inherited $name] }
    }
    return $values
}

proc ::machteld::devcache::with_native_environment {msys script} {
    set native [native_environment $msys]
    set present [info exists ::env(PATH)]
    if {$present} { set saved $::env(PATH) }
    set ::env(PATH) [dict get $native PATH]
    try { uplevel 1 $script } finally {
        if {$present} { set ::env(PATH) $saved } else { unset -nocomplain ::env(PATH) }
    }
}

proc ::machteld::devcache::native_shared_spec {root paths toolchainKey} {
    set files [list [file join $root tools buildlib.tcl]]
    lappend files {*}[lsort [glob -nocomplain -directory [file join $root src] *.h]]
    set trees [list [dict get $paths include]]
    foreach name {sqlite yyjson} {
        if {[dict exists $paths $name]} { lappend trees [dict get $paths $name] }
    }
    return [dict create values [list $toolchainKey] files $files trees $trees]
}

proc ::machteld::devcache::reference_version {root} {
    # Runtime implementation bytes belong to the package, not conversion.
    # Validate the two version declarations on every call, but key references
    # on the version value and authored interface documentation only.
    foreach path [list [file join $root src machteld.h] [file join $root tcl machteld.tcl]] \
            pattern {{(?m)^#define\s+MACHTELD_VERSION\s+"([0-9]+\.[0-9]+(?:\.[0-9]+)?)"\s*$} {(?m)^\s*variable\s+version\s+([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$}} {
        set ch [open $path r]
        try { set text [read $ch] } finally { close $ch }
        if {![regexp $pattern $text -> version]} { error "missing canonical runtime version: $path" }
        lappend versions $version
    }
    if {[lindex $versions 0] ne [lindex $versions 1]} { error "C/Tcl runtime version mismatch" }
    if {[regexp {package require machteld [0-9]} $text]} { error "Tcl wrap launcher carries a literal version pin" }
    return [lindex $versions 0]
}

# tools/reference.tcl runs on the build runtime, so the runtime that converts
# is an input too; the cache's tclsh90s runs the upstream converter and the
# final validator.
proc ::machteld::devcache::reference_spec {root cache tclsh} {
    set version [reference_version $root]
    set files [list $tclsh [file join $root LICENSE] [info nameofexecutable]]
    foreach name {reference.tcl dependencies.lock.json} { lappend files [file join $root tools $name] }
    foreach name {Tcl-9.0.4.txt Tk-9.0.4.txt} { lappend files [file join $root licenses $name] }
    # The generator currently requires these exact pinned archive names.
    foreach name {tcl904-src.zip tk904-src.zip} { lappend files [file join $cache downloads $name] }
    return [dict create values [list runtime_version $version] runtime_version_guard [list $root $version] \
        files $files trees [list [file join $root docs]]]
}

proc ::machteld::devcache::package_spec {root paths prelude bare bareGui reference} {
    set prefix [dict get $paths prefix]
    set files [list $prelude $bare $bareGui [dict get $paths tclsh] [file join $prefix bin wish90s.exe] [file join $root LICENSE]]
    foreach name {package.tcl build_identity.tcl} { lappend files [file join $root tools $name] }
    set trees [list [file join $root licenses] $reference]
    foreach name {lib/tcl9.0 tcl_library lib/tcl9 tcl9 lib/tk9.0 tk_library} {
        lappend trees [file join $prefix {*}[split $name /]]
    }
    return [dict create files $files trees $trees]
}
