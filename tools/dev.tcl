# tools/dev.tcl -- the fast development loop for machteld. NOT the release gate.
#
# Run through the z toolchain (z.json maps `z dev*` to `tclsh90 tools/dev.tcl`):
#     z devdocs           docs checks only, no build (seconds)
#     z devbuild          incremental build -> out/machteld.exe
#     z devtest LANE ...  incremental build, then the named pure-Tcl lane(s)
#     z devclean          delete the dev cache
#
# Speed comes from a PERSISTENT cache in .cache/dev that the hermetic release
# build never uses: the 9 MB SQLite amalgamation is compiled once and reused;
# authored src/*.c recompile only when they, a header, or the build description
# change; the reference corpus is reused unless a doc source is newer or -ref is
# given.
#
# THE RULE: this loop is for iteration and it MAY drift from a clean build
# (a stale object, a reused corpus). The release gate, tools/test.ps1, stays
# authoritative and hermetic, and runs at RELEASE boundaries: before a
# version ships, before a version bump, and after changes to the release
# tooling itself. Ordinary development commits push on this loop's checks;
# drift is caught at the next release gate, which is the point of having
# one. What gets compiled, and how, comes from tools/buildlib.tcl -- the same
# words the release build reads -- so a dev object is a release object; only
# the caching and the work directory differ.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ROOT [script_root]
proc Rp {args} { return [file join $::ROOT {*}$args] }
source [Rp tools buildlib.tcl]
namespace import ::machteld::build::run

# ---- toolchain discovery: the same order as tools/toolchain.ps1 ----

proc discover_msys2 {root} {
    set cands {}
    foreach name {MSYS2_ROOT Z_MSYS2} {
        if {[info exists ::env($name)] && $::env($name) ne ""} { lappend cands $::env($name) }
    }
    lappend cands C:/msys64 [file join [file dirname $root] .z r msys2]
    foreach p $cands {
        if {$p ne "" && [file exists [file join $p ucrt64 bin gcc.exe]]} {
            return [file normalize $p]
        }
    }
    error "dev.tcl: msys2 gcc not found; set MSYS2_ROOT (tried: [join $cands {, }])"
}
set MSYS2 [discover_msys2 $ROOT]
set GCC     [file join $MSYS2 ucrt64 bin gcc.exe]
set STRIP   [file join $MSYS2 ucrt64 bin strip.exe]
set WINDRES [file join $MSYS2 ucrt64 bin windres.exe]
if {![file exists $WINDRES]} { error "dev.tcl: missing windres: $WINDRES" }
set ::env(PATH) "[file nativename [file join $MSYS2 ucrt64 bin]];$::env(PATH)"

# ---- machteld's own bootstrapped dependency cache (from a prior release build) ----

set CACHE [::machteld::build::cache_root $ROOT]
if {[catch {::machteld::build::paths $CACHE} PATHS]} {
    error "dev.tcl: $PATHS\n  run tools/build.ps1 once to bootstrap [file nativename $CACHE]"
}
set TCLSH  [dict get $PATHS tclsh]
set PREFIX [dict get $PATHS prefix]

# ---- the persistent dev cache (absent from the release build) ----

set DEV [Rp .cache dev]
set OBJ [file join $DEV obj]
set REF [file join $DEV reference]
file mkdir $OBJ

set common [::machteld::build::common_flags $PATHS]

# Every authored object depends on every header and on the build description
# itself: an edited header or a changed flag must recompile the world, not
# only the file that happened to be saved.
proc inputs_mtime {} {
    set latest [file mtime [Rp tools buildlib.tcl]]
    foreach header [glob -nocomplain -directory [Rp src] *.h] {
        set t [file mtime $header]
        if {$t > $latest} { set latest $t }
    }
    return $latest
}
set ::INPUTS_MTIME [inputs_mtime]

# Compile src -> obj only when the object is missing or older than its inputs.
# Returns 1 if it compiled, 0 if the cached object was fresh. Vendor sources
# pass shared=0: they depend on nothing of ours.
proc cc {obj src flags label {shared 1}} {
    if {[file exists $obj] && [file mtime $obj] >= [file mtime $src] &&
            (!$shared || [file mtime $obj] >= $::INPUTS_MTIME)} { return 0 }
    puts "  cc  $label"
    run $::GCC {*}$flags -c $src -o $obj
    return 1
}

proc version_resource {kind obj} {
    set header [Rp src machteld.h]
    set generator [Rp tools generate-version-resource.tcl]
    if {[file exists $obj] &&
            [file mtime $obj] >= [file mtime $header] &&
            [file mtime $obj] >= [file mtime $generator]} {
        return 0
    }
    puts "  rc  machteld-$kind.rc"
    ::machteld::build::version_resource $::TCLSH $::WINDRES $::ROOT $kind \
        [file join $::OBJ "machteld-$kind.rc"] $obj
    return 1
}

# ---- the incremental build ----

proc dev_build {{forceRef 0}} {
    set changed 0
    puts "build: incremental (cache [file nativename $::DEV])"

    # Pinned third-party sources: SQLite and yyjson, cached across builds with
    # their own flags from buildlib.tcl, never the authored -Werror set.
    set sqliteObj [file join $::OBJ sqlite3.o]
    set yyjsonObj [file join $::OBJ yyjson.o]
    incr changed [cc $sqliteObj [file join [dict get $::PATHS sqlite] sqlite3.c] \
        $::machteld::build::SQLITE_FLAGS sqlite3.c 0]
    incr changed [cc $yyjsonObj [file join [dict get $::PATHS yyjson] yyjson.c] \
        $::machteld::build::YYJSON_FLAGS yyjson.c 0]
    # Authored translation units.
    set consoleMain [Rp src machteld_main.c]
    set guiMain     [Rp src machteld_gui_main.c]
    set objects {}
    foreach s [lsort [glob -directory [Rp src] *.c]] {
        if {$s eq $consoleMain || $s eq $guiMain} continue
        set o [file join $::OBJ [file rootname [file tail $s]].o]
        incr changed [cc $o $s $::common [file tail $s]]
        lappend objects $o
    }
    set consoleObj [file join $::OBJ machteld_main.o]
    incr changed [cc $consoleObj $consoleMain [concat $::common -municode] machteld_main.c]
    set guiObj [file join $::OBJ machteld_gui_main.o]
    incr changed [cc $guiObj $guiMain [concat $::common -municode] machteld_gui_main.c]
    set consoleVersionObj [file join $::OBJ machteld-console-resource.o]
    set guiVersionObj [file join $::OBJ machteld-gui-resource.o]
    incr changed [version_resource console $consoleVersionObj]
    incr changed [version_resource gui $guiVersionObj]

    # Link the two bare hosts when any object changed or a host is missing.
    set bare    [file join $::DEV machteld-bare.exe]
    set bareGui [file join $::DEV machteld-bare-gui.exe]
    if {$changed || ![file exists $bare] || ![file exists $bareGui]} {
        puts "  ld  machteld-bare.exe"
        ::machteld::build::link_host $::GCC $::STRIP console $consoleObj $consoleVersionObj \
            $objects $sqliteObj $yyjsonObj $::PATHS $bare
        puts "  ld  machteld-bare-gui.exe"
        ::machteld::build::link_host $::GCC $::STRIP gui $guiObj $guiVersionObj \
            $objects $sqliteObj $yyjsonObj $::PATHS $bareGui
    } else {
        puts "  ld  (bare hosts current)"
    }

    # Manifest + prelude: cheap, always regenerated -- but staged to a scratch
    # name and promoted only when the CONTENT changed, so an unchanged prelude
    # does not force repackaging.
    set manifest [file join $::OBJ manifest.tcl]
    run $::TCLSH [Rp tools genmanifest.tcl] [Rp src] $manifest
    set staged [file join $::OBJ prelude.tcl]
    set fresh  [file join $::OBJ prelude.new]
    ::machteld::build::stage_prelude $::ROOT $manifest $fresh
    set preludeChanged 1
    if {[file exists $staged] && [file size $staged] == [file size $fresh]} {
        set a [open $staged r]; fconfigure $a -translation binary
        set b [open $fresh  r]; fconfigure $b -translation binary
        set preludeChanged [expr {[read $a] ne [read $b]}]
        close $a; close $b
    }
    if {$preludeChanged} { file rename -force $fresh $staged } \
    else { file delete $fresh }

    # Reference corpus: reuse the cache unless forced or a doc source is newer.
    if {$forceRef || [ref_stale]} {
        puts "  ref generating corpus (this step uses the existing PowerShell generator)"
        file delete -force $::REF
        run powershell.exe -NoProfile -ExecutionPolicy Bypass \
            -File [Rp tools generate-reference.ps1] \
            -CacheRoot $::CACHE -Output $::REF -Tclsh $::TCLSH
        write_ref_stamp
    } else {
        puts "  ref (corpus current)"
    }

    # Package to out/machteld.exe -- skipped when the exe is already newer
    # than every ingredient (hosts, prelude content, corpus stamp).
    set final [Rp out machteld.exe]
    file mkdir [Rp out]
    if {!$preludeChanged && !$changed && [file exists $final]} {
        set t [file mtime $final]
        if {$t >= [file mtime $bare] && $t >= [file mtime $bareGui] &&
                $t >= [file mtime [ref_stamp]] && $t >= [file mtime $staged]} {
            puts "build: out/machteld.exe current ([file size $final] bytes)"
            return
        }
    }
    # package.tcl demands an absent candidate named like a build invocation:
    # .machteld-build-<32 hex>.exe.
    set id [format %016llx%08x%08x [clock microseconds] [pid] \
        [expr {int(rand() * 0xFFFFFFFF)}]]
    set cand [file join $::DEV ".machteld-build-$id.exe"]
    file delete -force $cand
    run $::TCLSH [Rp tools package.tcl] \
        --prefix $::PREFIX --prelude $staged --wrapper $bare --out $cand \
        --licenses [Rp licenses] --apache-license [Rp LICENSE] \
        --reference $::REF --embed-console $bare --embed-gui $bareGui
    file delete -force $final
    file rename -force $cand $final
    puts "build: out/machteld.exe  ([file size $final] bytes)"
}

# Corpus staleness: any authored doc or command page newer than the stamp.
proc ref_stamp {} { return [file join $::DEV reference.stamp] }
proc write_ref_stamp {} {
    set f [open [ref_stamp] w]; puts $f [clock seconds]; close $f
}
proc ref_stale {} {
    if {![file isdirectory $::REF] || ![file exists [ref_stamp]]} { return 1 }
    set stamp [file mtime [ref_stamp]]

    # A timestamp walk cannot notice a deleted source page. Compare the
    # authored and generated Machteld page sets before considering mtimes so a
    # removed command or guide cannot survive in the cached corpus.
    foreach pair [list \
            [list [Rp docs] [file join $::REF markdown machteld guide]] \
            [list [Rp docs reference machteld] [file join $::REF markdown machteld]] \
            [list [Rp docs reference machteld command] [file join $::REF markdown machteld command]]] {
        lassign $pair sourceDir generatedDir
        set sourceNames [lsort [lmap f [glob -nocomplain -directory $sourceDir *.md] {
            file tail $f
        }]]
        set generatedNames [lsort [lmap f [glob -nocomplain -directory $generatedDir *.md] {
            file tail $f
        }]]
        if {$sourceNames ne $generatedNames} { return 1 }
    }
    foreach pat {docs/*.md docs/reference/machteld/*.md docs/reference/machteld/command/*.md} {
        foreach f [glob -nocomplain [Rp {*}[split $pat /]]] {
            if {[file mtime $f] > $stamp} { return 1 }
        }
    }
    return 0
}

# ---- docs checks: no build ----

proc dev_docs {} {
    set fail 0
    # 1. Front matter and balanced code fences on every guide.
    foreach f [lsort [glob -nocomplain [Rp docs *.md]]] {
        set fh [open $f r]; fconfigure $fh -encoding utf-8; set text [read $fh]; close $fh
        set name [file tail $f]
        if {![string match "---\n*" $text]} {
            puts "  FAIL $name: no YAML front matter"; incr fail
        }
        set fences 0
        foreach line [split $text \n] { if {[string match "```*" $line]} { incr fences } }
        if {$fences % 2} { puts "  FAIL $name: unbalanced ``` fences ($fences)"; incr fail }
    }
    if {!$fail} { puts "  ok   front matter and code fences balanced ([llength [glob [Rp docs *.md]]] guides)" }

    # 2. The reference coverage/link checker (pure Tcl, no build).
    puts "  check_reference.tcl:"
    if {[catch {run $::TCLSH [Rp tools check_reference.tcl]} err]} {
        puts "  FAIL check_reference: $err"; incr fail
    } else {
        puts "  ok   reference links and coverage"
    }

    # 3. Every prose version claim agrees with src/machteld.h.
    if {[catch {run $::TCLSH [Rp tools check_version.tcl]} err]} {
        puts "  FAIL check_version: $err"; incr fail
    } else {
        puts "  ok   version claims agree with the header"
    }

    # 4. If a built exe exists, confirm each guide resolves in its corpus.
    set exe [Rp out machteld.exe]
    if {[file exists $exe]} {
        set probe [file join $::DEV docprobe.tcl]
        set ids {}
        foreach f [lsort [glob -nocomplain [Rp docs *.md]]] {
            lappend ids "machteld/guide/[file rootname [file tail $f]]"
        }
        set p [open $probe w]; fconfigure $p -translation lf
        puts $p "package require machteld"
        puts $p "set bad 0"
        puts $p "foreach id {$ids} {"
        puts $p {  if {[catch {docs get $id} e]} { puts "  FAIL corpus missing $id"; incr bad }}
        puts $p "}"
        puts $p {if {!$bad} { puts "  ok   built corpus resolves every guide" }}
        puts $p {exit [expr {$bad != 0}]}
        close $p
        if {[catch {run $exe $probe} err]} {
            puts "  FAIL corpus probe (built exe may be stale; z devbuild to refresh)"; incr fail
        }
    } else {
        puts "  --   no out/machteld.exe yet; z devbuild to check the built corpus"
    }
    if {$fail} { puts "docs: $fail problem(s)"; exit 1 }
    puts "docs: ok"
}

# ---- targeted test lanes (the pure-Tcl ones you iterate on) ----

# Lanes needing compiled C fixtures or basekit extraction (process, native,
# store, wrap, entry, embedded-reference generator) stay with the release gate.
set ::LANES {
    filesystem test/filesystem_test.tcl
    runtime    test/runtime_test.tcl
    reference  test/reference_test.tcl
    json       test/json_test.tcl
}

proc dev_test {lanes} {
    dev_build
    set exe [Rp out machteld.exe]
    if {![llength $lanes]} {
        puts "test: name one or more lanes: [dict keys $::LANES]"; exit 2
    }
    set fail 0
    foreach lane $lanes {
        if {![dict exists $::LANES $lane]} {
            puts "test: unknown lane '$lane' (known: [dict keys $::LANES]);"
            puts "      fixture-heavy lanes (process native store wrap entry) use tools/test.ps1"
            incr fail; continue
        }
        set path [Rp {*}[split [dict get $::LANES $lane] /]]
        puts "== lane $lane"
        if {[catch {run $exe $path} err]} { puts "  FAIL $lane"; incr fail } \
        else { puts "  ok   $lane" }
    }
    if {$fail} { puts "test: $fail lane(s) failed"; exit 1 }
    puts "test: ok"
}

proc dev_clean {} {
    file delete -force $::DEV
    puts "cleaned [file nativename $::DEV]"
}

# ---- dispatch ----

set task [lindex $argv 0]
set rest [lrange $argv 1 end]
switch -- $task {
    ""      { puts "tasks: docs | build ?-ref? | test LANE ... | clean" }
    docs    { dev_docs }
    build   { dev_build [expr {[lindex $rest 0] eq "-ref"}] }
    test    { dev_test $rest }
    clean   { dev_clean }
    default { puts "unknown task '$task' (docs build test clean)"; exit 2 }
}
