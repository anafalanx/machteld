# tools/dev.tcl -- the fast development loop for machteld. NOT the release gate.
#
# Run through the z toolchain (z.json maps `z dev*` to `tclsh90 tools/dev.tcl`):
#     z devdocs           docs checks only, no build (seconds)
#     z devbuild          incremental build -> out/machteld.exe
#     z devtest LANE ...  incremental build, then the named pure-Tcl lane(s)
#     z devclean          delete the dev cache
#
# Speed comes from a PERSISTENT cache in .cache/dev that the hermetic release
# build never uses: the 9 MB SQLite amalgamation and the 32 Lua sources are
# compiled once and reused; authored src/*.c recompile only when they change;
# the reference corpus is reused unless a doc source is newer or -ref is given.
#
# THE RULE: this loop is for iteration and it MAY drift from a clean build
# (a stale object, a reused corpus). The release gate, tools/test.ps1, stays
# authoritative and hermetic, and runs at RELEASE boundaries: before a
# version ships, before a version bump, and after changes to the release
# tooling itself. Ordinary development commits push on this loop's checks;
# drift is caught at the next release gate, which is the point of having
# one. Compile flags here are copied verbatim from tools/build.tcl so a dev
# object is byte-for-byte a release object; only the caching and the work
# directory differ.

proc script_root {} {
    set s [info script]
    if {[file pathtype $s] ne "absolute"} { set s [file join [pwd] $s] }
    return [file dirname [file dirname $s]]
}
set ROOT [script_root]
proc Rp {args} { return [file join $::ROOT {*}$args] }

# ---- toolchain discovery: gcc/strip from the z msys2 payload ----

proc discover_msys2 {root} {
    set cands {}
    if {[info exists ::env(Z_MSYS2)] && $::env(Z_MSYS2) ne ""} {
        lappend cands $::env(Z_MSYS2)
    }
    if {[info exists ::env(Z_HOME)] && $::env(Z_HOME) ne ""} {
        lappend cands [file join $::env(Z_HOME) r msys2]
    } elseif {[info exists ::env(Z_ROOT)] && $::env(Z_ROOT) ne ""} {
        lappend cands [file join $::env(Z_ROOT) .z r msys2]
    }
    lappend cands [file join [file dirname $root] .z r msys2]
    lappend cands C:/dev/.z/r/msys2
    foreach p $cands {
        if {$p ne "" && [file exists [file join $p ucrt64 bin gcc.exe]]} {
            return [file normalize $p]
        }
    }
    error "dev.tcl: msys2 gcc not found; set Z_MSYS2 (tried: [join $cands {, }])"
}
set MSYS2 [discover_msys2 $ROOT]
set GCC   [file join $MSYS2 ucrt64 bin gcc.exe]
set STRIP [file join $MSYS2 ucrt64 bin strip.exe]
set ::env(PATH) "[file nativename [file join $MSYS2 ucrt64 bin]];$::env(PATH)"

# ---- machteld's own bootstrapped dependency cache (from a prior release build) ----

set CACHE [expr {[info exists ::env(MACHTELD_DEPS_ROOT)] && $::env(MACHTELD_DEPS_ROOT) ne ""
                 ? [file normalize $::env(MACHTELD_DEPS_ROOT)] : [Rp .cache deps]}]
set PREFIX  [file join $CACHE prefix]
set SQLITE  [file join $CACHE sqlite]
set LUA     [file join $CACHE lua]
set INCLUDE [file join $PREFIX include]
proc need {label path} {
    if {![file exists $path]} {
        error "dev.tcl: missing $label: $path\n  run tools/build.ps1 once to bootstrap .cache/deps"
    }
    return $path
}
need "dependency cache" $CACHE
need "static tclsh" [set TCLSH [file join $PREFIX bin tclsh90s.exe]]
need "tcl.h"     [file join $INCLUDE tcl.h]
need "sqlite3.c" [file join $SQLITE sqlite3.c]
need "lua.h"     [file join $LUA lua.h]
set TCLLIB   [need "libtcl90.a"   [file join $PREFIX lib libtcl90.a]]
set TKLIB    [need "libtcl9tk90.a" [file join $PREFIX lib libtcl9tk90.a]]
set TCLSTUB  [need "libtclstub.a" [file join $PREFIX lib libtclstub.a]]

# ---- the persistent dev cache (absent from the release build) ----

set DEV [Rp .cache dev]
set OBJ [file join $DEV obj]
set REF [file join $DEV reference]
file mkdir $OBJ

# ---- compile flags: copied verbatim from tools/build.tcl ----

set warnings {-Wall -Wextra -Wpedantic -Wformat=2 -Wundef -Werror}
set defines {
    -DUNICODE -D_UNICODE -DSTATIC_BUILD=1
    -DMACHTELD_STATIC_SQLITE -DMACHTELD_PROC -DMACHTELD_JSON
    -DMACHTELD_PS -DMACHTELD_HASH -DMACHTELD_DIRS -DMACHTELD_HTTP
    -DMACHTELD_LUA
}
set common [list -std=c23 -O2 {*}$warnings {*}$defines \
    -ffunction-sections -fdata-sections -I$INCLUDE -I$SQLITE -I$LUA]
set syslibs {
    -lnetapi32 -lkernel32 -luser32 -ladvapi32 -luserenv -lws2_32
    -lgdi32 -lcomdlg32 -limm32 -lcomctl32 -lshell32 -luuid -lole32
    -loleaut32 -lwinspool -lpsapi -lbcrypt -lwinhttp
}

proc run {args} {
    if {[catch {exec {*}$args >@ stdout 2>@ stderr} message options]} {
        if {[dict exists $options -errorcode] &&
            [lindex [dict get $options -errorcode] 0] eq "CHILDSTATUS"} {
            error "command failed (exit [lindex [dict get $options -errorcode] 2])"
        }
        return -options $options $message
    }
}

# Compile src -> obj only when the object is missing or older than the source.
# Returns 1 if it compiled, 0 if the cached object was fresh.
proc cc {obj src flags label} {
    if {[file exists $obj] && [file mtime $obj] >= [file mtime $src]} { return 0 }
    puts "  cc  $label"
    run $::GCC {*}$flags -c $src -o $obj
    return 1
}

# ---- the incremental build ----

proc dev_build {{forceRef 0}} {
    set changed 0
    puts "build: incremental (cache [file nativename $::DEV])"

    # Pinned third-party sources: SQLite and Lua, cached across builds.
    incr changed [cc [file join $::OBJ sqlite3.o] [file join $::SQLITE sqlite3.c] \
        {-O2 -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION} sqlite3.c]
    set luaObjs {}
    foreach s [lsort [glob [file join $::LUA *.c]]] {
        set o [file join $::OBJ lua_[file rootname [file tail $s]].o]
        incr changed [cc $o $s {-O2} "lua/[file tail $s]"]
        lappend luaObjs $o
    }

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

    # Link the two bare hosts when any object changed or a host is missing.
    set bare    [file join $::DEV machteld-bare.exe]
    set bareGui [file join $::DEV machteld-bare-gui.exe]
    if {$changed || ![file exists $bare] || ![file exists $bareGui]} {
        puts "  ld  machteld-bare.exe"
        run $::GCC -municode -static-libgcc -Wl,--gc-sections \
            $consoleObj {*}$objects [file join $::OBJ sqlite3.o] {*}$luaObjs \
            $::TKLIB $::TCLLIB $::TCLSTUB {*}$::syslibs -o $bare
        run $::STRIP $bare
        puts "  ld  machteld-bare-gui.exe"
        run $::GCC -municode -mwindows -static-libgcc -Wl,--gc-sections \
            $guiObj {*}$objects [file join $::OBJ sqlite3.o] {*}$luaObjs \
            $::TKLIB $::TCLLIB $::TCLSTUB {*}$::syslibs -o $bareGui
        run $::STRIP $bareGui
    } else {
        puts "  ld  (bare hosts current)"
    }

    # Manifest + prelude: cheap, always regenerated (same file list as
    # build.tcl) -- but staged to a scratch name and promoted only when the
    # CONTENT changed, so an unchanged prelude does not force repackaging.
    set manifest [file join $::OBJ manifest.tcl]
    run $::TCLSH [Rp tools genmanifest.tcl] [Rp src] $manifest
    set staged [file join $::OBJ prelude.tcl]
    set fresh  [file join $::OBJ prelude.new]
    set out [open $fresh w]
    fconfigure $out -translation lf
    foreach part [list [Rp tcl machteld.tcl] [Rp tcl docs.tcl] [Rp tcl cli.tcl] \
            [Rp tcl log.tcl] [Rp tcl worker.tcl] [Rp tcl pool.tcl] [Rp tcl pmap.tcl] \
            [Rp tcl macht.tcl] $manifest] {
        set in [open $part r]; fconfigure $in -translation lf
        puts $out [read $in]; close $in
    }
    close $out
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

    # 3. If a built exe exists, confirm each guide resolves in its corpus.
    set exe [Rp out machteld.exe]
    if {[file exists $exe]} {
        set probe [file join $::DEV docprobe.tcl]
        set ids {}
        foreach f [lsort [glob -nocomplain [Rp docs *.md]]] {
            lappend ids "machteld/guide/[file rootname [file tail $f]]"
        }
        set p [open $probe w]; fconfigure $p -translation lf
        puts $p "package require machteld 0.11.0"
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
    macht      test/macht_test.tcl
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
