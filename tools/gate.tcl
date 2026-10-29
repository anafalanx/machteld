package require machteld 0.21

# tools/gate.tcl -- the release gate: build (unless --skip-build), compile the
# test fixtures with the pinned toolchain, run the drivers that check the host
# from outside (entry, package, VERSIONINFO, reference generator, reference
# coverage, version consistency), then run every runtime lane on the host
# itself. The first failure stops the gate.
#
#     machteld.exe tools/gate.tcl ?--runtime EXE? ?--cache DIR? ?--msys DIR?
#         ?--skip-build? ?--public-tls? ?--interactive-pty?
#
# The drivers run on the build runtime, the lanes on the host under test.
# --public-tls and --interactive-pty enable the lanes' opt-in network and
# console checks. The Tcl port (2026-10-28) of tools/test.ps1.

namespace eval ::gate {
    namespace path ::machteld
    variable root [file dirname [file dirname [file normalize [info script]]]]
}
source -encoding utf-8 [file join $::gate::root tools bootstrap.tcl]

proc ::gate::fail {message} {
    return -code error -errorcode {GATE fail} "gate: $message"
}

# Runs one gate step on this console; `-env dict` before the command overlays
# the environment.
proc ::gate::step {label args} {
    set env {}
    if {[lindex $args 0] eq "-env"} {
        set args [lassign $args - env]
    }
    puts "\n== $label =="
    flush stdout
    set result [run -inherit -env $env -- {*}$args]
    if {[dict get $result exit] != 0 || [dict get $result status] ne "ok"} {
        fail "$label failed with exit code [dict get $result exit]"
    }
}

proc ::gate::main {argv} {
    variable root
    set runtime [file join $root out machteld.exe]
    set cache [file join $root .cache deps]
    set msysRequested ""
    set build 1
    set laneEnv {}
    while {[llength $argv]} {
        set argv [lassign $argv option]
        switch -- $option {
            --runtime {set argv [lassign $argv runtime]}
            --cache {set argv [lassign $argv cache]}
            --msys {set argv [lassign $argv msysRequested]}
            --skip-build {set build 0}
            --public-tls {lappend laneEnv MACHTELD_TEST_PUBLIC_TLS 1}
            --interactive-pty {lappend laneEnv MACHTELD_TEST_PTY_IO 1}
            default {fail "unknown option $option"}
        }
    }
    set runtime [file normalize $runtime]
    set cache [file normalize $cache]
    set msys [::boot::msysRoot $msysRequested]
    set driver [info nameofexecutable]

    if {$build} {
        step build $driver [file join $root tools release.tcl] --output $runtime --cache $cache --msys $msys
    }
    if {![file isfile $runtime]} {
        fail "runtime not found: [file nativename $runtime]"
    }

    set bin [file join $msys ucrt64 bin]
    set gcc [file join $bin gcc.exe]
    set sqlite [file join $cache sqlite]
    set tclsh [file join $cache prefix bin tclsh90s.exe]
    foreach {tool label} [list $gcc "MSYS2 gcc" $tclsh "the dependency cache's static tclsh"] {
        if {![file isfile $tool]} {
            fail "$label not found: [file nativename $tool]"
        }
    }
    set outputDir [file join $root out test]
    file mkdir $outputDir
    # gcc's cc1, as and ld load their DLLs from ucrt64/bin.
    set gccEnv [list PATH "[file nativename $bin];$::env(PATH)"]
    set strict {-std=c23 -O2 -Wall -Wextra -Werror}

    set processFixture [file join $outputDir process_fixture.exe]
    step "fixture process_fixture.c" -env $gccEnv $gcc {*}$strict -municode \
        [file join $root test fixtures process_fixture.c] -o $processFixture
    set httpFixture [file join $outputDir http_fixture.exe]
    step "fixture http_fixture.c" -env $gccEnv $gcc {*}$strict -municode \
        [file join $root test fixtures http_fixture.c] -lws2_32 -o $httpFixture
    set sqliteObject [file join $outputDir sqlite3-test.o]
    step "SQLite test object" -env $gccEnv $gcc -O2 -w -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION \
        -c [file join $sqlite sqlite3.c] -o $sqliteObject
    set lockFixture [file join $outputDir sqlite_lock_fixture.exe]
    step "fixture sqlite_lock_fixture.c" -env $gccEnv $gcc {*}$strict -municode \
        [file join $root test fixtures sqlite_lock_fixture.c] -I $sqlite $sqliteObject -o $lockFixture
    set cmdline [file join $outputDir cmdline_test.exe]
    step "fixture cmdline_test.c" -env $gccEnv $gcc {*}$strict -I [file join $root src] \
        [file join $root test cmdline_test.c] [file join $root src winjob_cmdline.c] -o $cmdline
    # Everything from here runs with MSYS2 on PATH, as under the PowerShell
    # gate, so a fixture that links a toolchain DLL still loads.
    step "cmdline golden vectors" -env $gccEnv $cmdline

    # The bare host is the packaged console basekit: the payload-refusal check
    # runs it with nothing appended.
    set bareHost [file join $outputDir .machteld-entry-basekit-[pid]-[binary encode hex [hash random 16]].exe]
    set mount gate-basekit-[pid]
    zipfs mount $runtime $mount
    try {
        file copy //zipfs:/$mount/basekit/console.exe $bareHost
    } finally {
        zipfs unmount $mount
    }
    try {
        step entry -env $gccEnv $driver [file join $root test entry_test.tcl] $runtime --fixture $processFixture --bare $bareHost
    } finally {
        file delete $bareHost
    }
    step package $driver [file join $root test package_test.tcl] --tclsh $tclsh
    step VERSIONINFO $driver [file join $root test version_resource_test.tcl] $runtime --cache $cache
    step "reference generator" $driver [file join $root test reference_generator_test.tcl] --cache $cache --tclsh $tclsh
    step "reference coverage" $tclsh [file join $root tools check_reference.tcl]
    step "version consistency" $tclsh [file join $root tools check_version.tcl]

    foreach {label script fixtures} [list \
            process process_test.tcl [list $processFixture] \
            store store_test.tcl [list $lockFixture] \
            native native_test.tcl [list $httpFixture $processFixture] \
            filesystem filesystem_test.tcl {} \
            "runtime services" runtime_test.tcl {} \
            "embedded reference" reference_test.tcl {} \
            JSONTestSuite json_test.tcl {} \
            wrap/basekits wrap_test.tcl {}] {
        puts "\n== $label =="
        flush stdout
        set result [run -inherit -env [concat $gccEnv $laneEnv] -- $runtime [file join $root test $script] {*}$fixtures]
        if {[dict get $result exit] != 0 || [dict get $result status] ne "ok"} {
            fail "$label failed with exit code [dict get $result exit]"
        }
    }
    puts "\nALL TEST LANES PASSED"
}

if {[file normalize [info script]] eq [file normalize $::argv0]} {
    try {
        ::gate::main $argv
    } trap {GATE fail} {message} {
        puts stderr $message
        exit 1
    } trap {BOOTSTRAP fail} {message} {
        puts stderr $message
        exit 1
    }
}
