# Content-addressed development stages. This file is sourceable by tests and
# has no compiler/bootstrap side effects. Records are inert Tcl dicts, never
# sourced. Missing, legacy, damaged or mismatched records are cache misses.
namespace eval ::machteld::devcache {
    variable directory [file dirname [file normalize [info script]]]
    variable helper ""
}

# pwsh supplies its own PSModulePath to Tcl children. Passing that on to Windows
# PowerShell can shadow built-in modules (including Get-FileHash). Let WinPS
# construct its native default and restore the caller's environment immediately.
proc ::machteld::devcache::windows_powershell {script} {
    set present [info exists ::env(PSModulePath)]
    if {$present} { set saved $::env(PSModulePath); unset ::env(PSModulePath) }
    try { uplevel 1 $script } finally { if {$present} { set ::env(PSModulePath) $saved } }
}

proc ::machteld::devcache::request {operation args} {
    variable directory
    variable helper
    if {$helper eq ""} {
        set helper [windows_powershell [list open [list | powershell.exe -NoProfile -ExecutionPolicy Bypass \
            -File [file join $directory dev-hash.ps1] -OwnerProcessId [pid]] r+]]
        fconfigure $helper -encoding utf-8 -translation {auto lf} -buffering line
    }
    set words [list $operation]
    foreach arg $args { lappend words [binary encode base64 -maxlen 0 [encoding convertto utf-8 $arg]] }
    puts $helper [join $words \t]
    flush $helper
    if {[gets $helper reply] < 0} { error "development cache hashing helper exited" }
    lassign [split $reply \t] status value
    if {$status eq "error"} { error [encoding convertfrom utf-8 [binary decode base64 $value]] }
    if {$status ne "ok"} { error "invalid development cache helper response" }
    return $value
}

proc ::machteld::devcache::shutdown {} {
    variable helper
    if {$helper ne ""} {
        # Cleanup must not hide the build failure if the helper itself exited.
        catch {request quit}
        catch {close $helper}
        set helper ""
    }
}

proc ::machteld::devcache::clean {directory} {
    set directory [file normalize $directory]
    if {![file isdirectory $directory]} { return }
    # Same handle lock as dev_build; refusing contention happens before any
    # deletion. The empty lock file stays behind and is never a stale claim.
    set lock [file join $directory build.lock]
    request lock $lock
    try { request clean $directory } finally { catch {request unlock $lock} }
}

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
                lappend material $path [request [expr {$field eq "files" ? "file" : "tree"}] $path]
            }
        }
    }
    return [request text $material]
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
    return [format %016llx%08x%08x [clock microseconds] [pid] [expr {int(rand()*0xffffffff)}]]
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

proc ::machteld::devcache::publish {candidate output} {
    variable directory
    windows_powershell [list exec powershell.exe -NoProfile -ExecutionPolicy Bypass \
        -File [file join $directory publish-output.ps1] -Candidate $candidate -Output $output >@ stdout 2>@ stderr]
}

proc ::machteld::devcache::record {path key outputs} {
    foreach output $outputs { if {![file exists $output]} { error "cannot record absent output: $output" } }
    set data [dict create schema 1 input $key outputs $outputs output [fingerprint [output_spec $outputs]]]
    set fresh [cache_candidate $path]
    try {
        set ch [open $fresh {WRONLY CREAT EXCL}]
        fconfigure $ch -encoding utf-8 -translation lf
        try { puts $ch $data } finally { close $ch }
        request publish $fresh $path
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
        if {$executable} { publish $fresh $output } else { request publish $fresh $output }
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

proc ::machteld::devcache::dependency_spec {root cache} {
    set files {}
    foreach name {dependencies.lock.json bootstrap.ps1 bootstrap-deps.sh toolchain.ps1 toolchain-fingerprint.ps1} {
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
# the caller's full environment for Git, hashing helpers and the build guard.
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

proc ::machteld::devcache::reference_spec {root cache tclsh} {
    set version [reference_version $root]
    set files [list $tclsh [file join $root LICENSE]]
    foreach name {generate-reference.ps1 reference-data.cs reference-cache.ps1 dependencies.lock.json} { lappend files [file join $root tools $name] }
    foreach name {Tcl-9.0.4.txt Tk-9.0.4.txt} { lappend files [file join $root licenses $name] }
    # The generator currently requires these exact pinned archive names.
    foreach name {tcl904-src.zip tk904-src.zip} { lappend files [file join $cache downloads $name] }
    return [dict create values [list runtime_version $version] runtime_version_guard [list $root $version] \
        files $files trees [list [file join $root docs]]]
}

proc ::machteld::devcache::package_spec {root paths prelude bare bareGui reference} {
    set prefix [dict get $paths prefix]
    set files [list $prelude $bare $bareGui [dict get $paths tclsh] [file join $prefix bin wish90s.exe] [file join $root LICENSE]]
    foreach name {package.tcl publish-output.ps1 build_identity.tcl} { lappend files [file join $root tools $name] }
    set trees [list [file join $root licenses] $reference]
    foreach name {lib/tcl9.0 tcl_library lib/tcl9 tcl9 lib/tk9.0 tk_library} {
        lappend trees [file join $prefix {*}[split $name /]]
    }
    return [dict create files $files trees $trees]
}
