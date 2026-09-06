# tools/buildlib.tcl -- the one description of what the Machteld hosts are.
#
# Sourced by tools/build.tcl (the hermetic release build) and tools/dev.tcl
# (the incremental development loop). Both compile the same translation units
# with the same flags, link the same libraries, and stage the same prelude;
# only caching and work directories differ. Everything that decides what the
# executable IS lives here, so the two loops cannot drift apart: a dev object is
# a release object because it is built by the same words.

namespace eval ::machteld::build {
    namespace export run
}

# Authored translation units under src/ compile with the full warning set.
# -Werror is the release default: the toolchain is hash-pinned, so a warning is
# deterministic and a release must not carry one. MACHTELD_WERROR=0 turns it off
# for exploration only; the gate never runs that way.
set ::machteld::build::WARNINGS {-Wall -Wextra -Wpedantic -Wformat=2 -Wundef}
set ::machteld::build::DEFINES {
    -DUNICODE -D_UNICODE -DSTATIC_BUILD=1
    -DMACHTELD_STATIC_SQLITE -DMACHTELD_PROC -DMACHTELD_JSON
    -DMACHTELD_PS -DMACHTELD_HASH -DMACHTELD_DIRS -DMACHTELD_HTTP
}

# Vendor translation units are pinned third-party source and compile with their
# own minimal flags, never the authored warning gate. SQLite is serialized,
# cannot load extensions at run time, and takes the upstream hardening
# recommended for an embed that issues only fixed queries: no double-quoted
# string literals, no deprecated interfaces, no shared cache.
set ::machteld::build::SQLITE_FLAGS {
    -O2 -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION
    -DSQLITE_DQS=0 -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE
}
set ::machteld::build::YYJSON_FLAGS {-O2 -ffunction-sections -fdata-sections}

set ::machteld::build::SYSLIBS {
    -lnetapi32 -lkernel32 -luser32 -ladvapi32 -luserenv -lws2_32
    -lgdi32 -lcomdlg32 -limm32 -lcomctl32 -lshell32 -luuid -lole32
    -loleaut32 -lwinspool -lpsapi -lbcrypt -lwinhttp
}

# Prelude parts in sourcing order: machteld.tcl first (it defines Fail,
# MetaDefine, and the version every later part reads); the generated manifest
# is appended last by stage_prelude.
set ::machteld::build::PRELUDE_PARTS {
    machteld.tcl docs.tcl cli.tcl log.tcl worker.tcl pool.tcl pmap.tcl
}

proc ::machteld::build::werror {} {
    return [expr {![info exists ::env(MACHTELD_WERROR)] || $::env(MACHTELD_WERROR) ne "0"}]
}

# The flags for one authored translation unit.
proc ::machteld::build::common_flags {paths} {
    variable WARNINGS
    variable DEFINES
    set flags [list -std=c23 -O2 {*}$WARNINGS]
    if {[werror]} { lappend flags -Werror }
    lappend flags {*}$DEFINES -ffunction-sections -fdata-sections \
        -I[dict get $paths include] -I[dict get $paths sqlite] -I[dict get $paths yyjson]
    return $flags
}

# Run a tool, streaming its output, and turn a nonzero exit into an error that
# names the tool and its exit code rather than Tcl's generic "child process
# exited abnormally".
proc ::machteld::build::run {args} {
    if {[catch {exec {*}$args >@ stdout 2>@ stderr} message options]} {
        if {[dict exists $options -errorcode] &&
                [lindex [dict get $options -errorcode] 0] eq "CHILDSTATUS"} {
            error "command failed (exit [lindex [dict get $options -errorcode] 2]): [file tail [lindex $args 0]]"
        }
        return -options $options $message
    }
}

proc ::machteld::build::first_existing {label candidates} {
    foreach path $candidates { if {[file exists $path]} { return $path } }
    error "missing $label; tried [join $candidates {, }]"
}

# The dependency cache root: MACHTELD_DEPS_ROOT, or .cache/deps under the
# repository.
proc ::machteld::build::cache_root {root} {
    if {[info exists ::env(MACHTELD_DEPS_ROOT)] && $::env(MACHTELD_DEPS_ROOT) ne ""} {
        return [file normalize $::env(MACHTELD_DEPS_ROOT)]
    }
    return [file join $root .cache deps]
}

# The dependency cache created by tools/bootstrap.ps1, located tolerant of
# upstream install-name variants. Every consumer asks this dict rather than
# spelling the layout itself. Raises when a required input is absent.
proc ::machteld::build::paths {cache} {
    set prefix [file join $cache prefix]
    set paths [dict create \
        cache $cache \
        prefix $prefix \
        include [file join $prefix include] \
        sqlite [file join $cache sqlite] \
        yyjson [file join $cache yyjson] \
        tclsh [first_existing "static tclsh" [list \
            [file join $prefix bin tclsh90s.exe] [file join $prefix bin tclsh90.exe]]] \
        tcllib [first_existing "static Tcl library" [list \
            [file join $prefix lib libtcl90.a] [file join $prefix lib libtcl9.0.a]]] \
        tklib [first_existing "static Tk library" [list \
            [file join $prefix lib libtcl9tk90.a] [file join $prefix lib libtk90.a] \
            [file join $prefix lib libtk9.0.a]]] \
        tclstub [first_existing "Tcl stub library" [list \
            [file join $prefix lib libtclstub.a] [file join $prefix lib libtclstub90.a]]]]
    foreach {label directory name} {
        tcl.h include tcl.h
        sqlite3.c sqlite sqlite3.c
        sqlite3.h sqlite sqlite3.h
        yyjson.c yyjson yyjson.c
    } {
        set path [file join [dict get $paths $directory] $name]
        if {![file exists $path]} { error "missing $label: $path" }
    }
    return $paths
}

# Generate and compile one host's VERSIONINFO resource from the canonical header.
proc ::machteld::build::version_resource {tclsh windres root kind rc object} {
    run $tclsh [file join $root tools generate-version-resource.tcl] \
        [file join $root src machteld.h] $kind $rc
    run $windres --codepage=65001 -O coff -i $rc -o $object
}

# Concatenate the prelude parts and the generated manifest, LF-only, into output.
proc ::machteld::build::stage_prelude {root manifest output} {
    variable PRELUDE_PARTS
    set files {}
    foreach part $PRELUDE_PARTS { lappend files [file join $root tcl $part] }
    lappend files $manifest
    set out [open $output w]
    fconfigure $out -translation lf
    foreach file $files {
        set in [open $file r]
        fconfigure $in -translation lf
        puts $out [read $in]
        close $in
    }
    close $out
}

# Link one bare host and strip it. `subsystem` is console or gui.
proc ::machteld::build::link_host {gcc strip subsystem mainobj resobj objects sqliteobj yyjsonobj paths output} {
    variable SYSLIBS
    set flags [list -municode -static-libgcc -Wl,--gc-sections]
    if {$subsystem eq "gui"} { lappend flags -mwindows }
    run $gcc {*}$flags $mainobj $resobj {*}$objects $sqliteobj $yyjsonobj \
        [dict get $paths tklib] [dict get $paths tcllib] [dict get $paths tclstub] \
        {*}$SYSLIBS -o $output
    if {$strip ne "" && [file exists $strip]} { run $strip $output }
}
