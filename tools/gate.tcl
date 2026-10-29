package require machteld 0.21

# tools/gate.tcl -- the release gate. With no --group it builds the runtime
# (unless --skip-build) and runs every group on it; with --group it runs the
# named groups, in that order, on the runtime as it is, and builds nothing.
#
#     machteld.exe tools/gate.tcl ?--group NAME ...? ?--runtime EXE? ?--cache DIR?
#         ?--msys DIR? ?--skip-build? ?--public-tls? ?--interactive-pty?
#         ?--interactive-gui? ?--native-scaling?
#
# The groups (the candidate's tools/test.ps1 groups, machteld 8bcc1ec):
#
#   fast                 no compiler and no MSYS2: reference coverage, version
#                        claims and their regressions, build identity, this
#                        gate's own test, and the runtime lanes that need no
#                        fixture (filesystem, runtime services, protocol, GUI
#                        model, embedded reference, README examples,
#                        JSONTestSuite, native adversarial inputs and
#                        filesystem boundaries)
#   integration          the C fixtures, the command-line golden vectors, the
#                        development cache, and the process, store, native and
#                        streaming-bounds lanes
#   packaging            the runtime's build identity, entry, package and
#                        publication, VERSIONINFO, wrap and basekits, the README
#                        examples wrapped, wrap inventory, the examples packaged
#   native-validation    native lifetime with the telemetry probe
#   reference-generator  two cold reference generations, byte for byte
#   release              alone: the build, then every group above (the default)
#
# Off by default, each behind its own option, none of it in a release run:
#
#   --public-tls         (integration or release) the native lane's public TLS
#                        checks, which reach the network
#   --interactive-pty    (integration or release) the process lane's console I/O
#   --interactive-gui    gui_widget_test, and the wrapped fixture's own window:
#                        both open windows, so this is the owner's check only
#   --native-scaling     (native-validation or release) the observational
#                        worker-scaling lane, whose timings are not a gate
#
# The drivers run on the build runtime (this one), the lanes on the runtime
# under test, the Tcl-only checks on the dependency cache's static tclsh. The
# gate removes every inherited MACHTELD_TEST_* and MACHTELD_WRAP_GUI_* variable
# before its lanes and sets only what its options ask for (an opt-in set in the
# shell no longer reaches a lane); it refuses MACHTELD_WERROR=0; it names the
# tested executable by version and SHA-256 and fails when it changes during
# the run; it prints PASS and the seconds of each step. The first failure
# stops it.

namespace eval ::gate {
    namespace path ::machteld
    variable root [file dirname [file dirname [file normalize [info script]]]]
    variable groups {fast integration packaging native-validation reference-generator}
    # What a lane reads to widen what it checks (the opt-ins) or to replace
    # what it tests (the worker-source overlay, the fixture PID file).
    variable lanePatterns {MACHTELD_TEST_* MACHTELD_WRAP_GUI_*}
    variable optins {
        tls MACHTELD_TEST_PUBLIC_TLS
        pty MACHTELD_TEST_PTY_IO
        gui MACHTELD_WRAP_GUI_INTERACTIVE
    }
}
source -encoding utf-8 [file join $::gate::root tools bootstrap.tcl]

proc ::gate::fail {message} {
    return -code error -errorcode {GATE fail} "gate: $message"
}

# The gate's settings from its arguments, checked: which groups run, whether
# the runtime is built, the paths, and the opt-ins.
proc ::gate::parse {argv} {
    variable root
    variable groups
    set settings [dict create runtime [file join $root out machteld.exe] \
        cache [file join $root .cache deps] msys "" skipBuild 0 \
        tls 0 pty 0 gui 0 scaling 0]
    set requested {}
    while {[llength $argv]} {
        set argv [lassign $argv option]
        switch -- $option {
            --group - --runtime - --cache - --msys {
                if {![llength $argv]} {
                    fail "$option needs a value"
                }
                set argv [lassign $argv value]
                if {$option eq "--group"} {
                    lappend requested $value
                } else {
                    dict set settings [string range $option 2 end] $value
                }
            }
            --skip-build {dict set settings skipBuild 1}
            --public-tls {dict set settings tls 1}
            --interactive-pty {dict set settings pty 1}
            --interactive-gui {dict set settings gui 1}
            --native-scaling {dict set settings scaling 1}
            default {fail "unknown option $option"}
        }
    }
    set selected {}
    foreach name $requested {
        if {$name ni [concat $groups release]} {
            fail "unknown group $name (known: [join [concat $groups release] {, }])"
        }
        if {$name ni $selected} {
            lappend selected $name
        }
    }
    set release [expr {![llength $selected] || $selected eq "release"}]
    if {!$release && "release" in $selected} {
        fail "release must be selected alone"
    }
    dict set settings release $release
    dict set settings groups [expr {$release ? $groups : $selected}]
    dict set settings build [expr {$release && ![dict get $settings skipBuild]}]
    set chosen [dict get $settings groups]
    if {([dict get $settings tls] || [dict get $settings pty]) && "integration" ni $chosen} {
        fail "--public-tls and --interactive-pty need the integration or release group"
    }
    if {[dict get $settings scaling] && "native-validation" ni $chosen} {
        fail "--native-scaling needs the native-validation or release group"
    }
    return $settings
}

proc ::gate::anyOf {wanted chosen} {
    foreach group $wanted {
        if {$group in $chosen} {
            return 1
        }
    }
    return 0
}

# Whether the selected work needs the runtime under test, MSYS2 (gcc), or the
# dependency cache's tclsh. The fast group needs no MSYS2.
proc ::gate::needs {settings what} {
    set chosen [dict get $settings groups]
    switch -- $what {
        runtime {
            expr {[dict get $settings gui] || [anyOf {fast integration packaging native-validation} $chosen]}
        }
        msys {
            expr {[dict get $settings build] || [anyOf {integration packaging native-validation} $chosen]}
        }
        tclsh {
            anyOf {fast packaging reference-generator} $chosen
        }
    }
}

# Plans one step unless a step with the same argv is planned already.
proc ::gate::addStep {stepsVar group label argv args} {
    upvar 1 $stepsVar steps
    foreach step $steps {
        if {[dict get $step argv] eq $argv} {
            return
        }
    }
    lappend steps [dict create group $group label $label argv $argv {*}$args]
}

# Plans one lane: a test program run on the runtime under test.
proc ::gate::addLane {stepsVar runtime group label script args} {
    variable root
    upvar 1 $stepsVar steps
    addStep steps $group $label [list $runtime [file join $root test $script] {*}$args]
}

# The steps of the selected groups, in order, after the build: each a dict
# with group, label and argv, and optionally expect (the exit code, 0 by
# default), timeout and bare (a path where the packaged console basekit is
# put for the step and deleted after it). A step already planned (the same
# argv) is not planned twice.
proc ::gate::plan {settings} {
    variable root
    set runtime [file normalize [dict get $settings runtime]]
    set cache [file normalize [dict get $settings cache]]
    set msys [dict get $settings msys]
    set driver [info nameofexecutable]
    set tclsh [file join $cache prefix bin tclsh90s.exe]
    set out [file join $root out test]
    set test [file join $root test]
    set chosen [dict get $settings groups]
    set gcc [file join $msys ucrt64 bin gcc.exe]
    set strict {-std=c23 -O2 -Wall -Wextra -Werror}
    set processFixture [file join $out process_fixture.exe]

    set steps {}
    # The process fixture serves three groups; it is compiled once, first.
    if {[anyOf {integration packaging native-validation} $chosen]} {
        addStep steps fixtures "fixture process_fixture.c" [list $gcc {*}$strict -municode \
            [file join $test fixtures process_fixture.c] -o $processFixture]
    }
    foreach group $chosen {
        switch -- $group {
            fast {
                addStep steps fast "reference coverage" [list $tclsh [file join $root tools check_reference.tcl]]
                addStep steps fast "version consistency" [list $tclsh [file join $root tools check_version.tcl]]
                addStep steps fast "version-check regressions" [list $tclsh [file join $test check_version_test.tcl]]
                addStep steps fast "build identity" [list $tclsh [file join $test build_identity_test.tcl]]
                addStep steps fast "gate groups and environment" [list $driver [file join $test gate_test.tcl]]
                addLane steps $runtime fast filesystem filesystem_test.tcl
                addLane steps $runtime fast "runtime services" runtime_test.tcl
                addLane steps $runtime fast protocol protocol_test.tcl
                addLane steps $runtime fast "GUI model" gui_model_test.tcl
                addLane steps $runtime fast "embedded reference" reference_test.tcl
                addLane steps $runtime fast "README examples" documentation_examples_test.tcl
                addLane steps $runtime fast JSONTestSuite json_test.tcl
                addLane steps $runtime fast "native adversarial inputs" native_adversarial_test.tcl
                addLane steps $runtime fast "native filesystem boundaries" native_filesystem_test.tcl
            }
            integration {
                set httpFixture [file join $out http_fixture.exe]
                set sqliteObject [file join $out sqlite3-test.o]
                set lockFixture [file join $out sqlite_lock_fixture.exe]
                set cmdline [file join $out cmdline_test.exe]
                set sqlite [file join $cache sqlite]
                addStep steps integration "fixture http_fixture.c" [list $gcc {*}$strict -municode \
                    [file join $test fixtures http_fixture.c] -lws2_32 -o $httpFixture]
                addStep steps integration "SQLite test object" [list $gcc -O2 -w -DSQLITE_THREADSAFE=1 \
                    -DSQLITE_OMIT_LOAD_EXTENSION -c [file join $sqlite sqlite3.c] -o $sqliteObject]
                addStep steps integration "fixture sqlite_lock_fixture.c" [list $gcc {*}$strict -municode \
                    [file join $test fixtures sqlite_lock_fixture.c] -I $sqlite $sqliteObject -o $lockFixture]
                addStep steps integration "fixture cmdline_test.c" [list $gcc {*}$strict -I [file join $root src] \
                    [file join $test cmdline_test.c] [file join $root src winjob_cmdline.c] -o $cmdline]
                addStep steps integration "command-line golden vectors" [list $cmdline]
                addStep steps integration "development cache" [list $driver [file join $test dev_cache_test.tcl] --msys $msys]
                addLane steps $runtime integration process process_test.tcl $processFixture
                addLane steps $runtime integration store store_test.tcl $lockFixture
                addLane steps $runtime integration native native_test.tcl $httpFixture $processFixture
                addLane steps $runtime integration "streaming bounds" streaming_bounds_test.tcl $processFixture
            }
            packaging {
                set bare [file join $out .machteld-entry-basekit-[pid]-[binary encode hex [hash random 16]].exe]
                addStep steps packaging "build identity of the runtime" [list $tclsh [file join $test build_identity_test.tcl] $runtime]
                addStep steps packaging entry [list $driver [file join $test entry_test.tcl] $runtime \
                    --fixture $processFixture --bare $bare] bare $bare
                addStep steps packaging "package and publication" [list $driver [file join $test package_test.tcl] --tclsh $tclsh]
                addStep steps packaging VERSIONINFO [list $driver [file join $test version_resource_test.tcl] $runtime --cache $cache]
                addLane steps $runtime packaging wrap/basekits wrap_test.tcl
                addLane steps $runtime packaging "README examples wrapped" documentation_examples_test.tcl --packaging
                addLane steps $runtime packaging "wrap inventory" wrap_inventory_test.tcl
                addLane steps $runtime packaging "examples packaged" examples_package_test.tcl $msys [file join $cache prefix]
            }
            native-validation {
                set probe [file join $out native_probe.dll]
                addStep steps native-validation "fixture native_probe.c" [list $gcc {*}$strict -shared -DUSE_TCL_STUBS \
                    -I [file join $cache prefix include] [file join $test fixtures native_probe.c] \
                    [file join $cache prefix lib libtclstub.a] -lpsapi -o $probe]
                addLane steps $runtime native-validation "native adversarial inputs" native_adversarial_test.tcl
                addLane steps $runtime native-validation "native filesystem boundaries" native_filesystem_test.tcl
                addLane steps $runtime native-validation "native lifecycle" native_lifecycle_test.tcl $probe $processFixture
                if {[dict get $settings scaling]} {
                    addLane steps $runtime native-validation "native scaling (observational)" native_scaling_test.tcl $probe $processFixture
                }
            }
            reference-generator {
                addStep steps reference-generator "reference generator" [list $driver \
                    [file join $test reference_generator_test.tcl] --cache $cache --tclsh $tclsh]
            }
        }
    }
    if {[dict get $settings gui]} {
        addLane steps $runtime interactive "GUI widgets (opens windows)" gui_widget_test.tcl
    }
    return $steps
}

# Runs script in the lanes' environment: every inherited MACHTELD_TEST_* and
# MACHTELD_WRAP_GUI_* variable removed, then only the requested opt-ins set,
# and compilerBin (when given) first on PATH. The caller's environment comes
# back afterwards, whether the script succeeds or fails.
proc ::gate::withLaneEnvironment {settings compilerBin script} {
    variable lanePatterns
    variable optins
    set saved {}
    foreach name [array names ::env] {
        foreach pattern $lanePatterns {
            if {[string match -nocase $pattern $name]} {
                dict set saved $name $::env($name)
                break
            }
        }
    }
    set pathPresent [info exists ::env(PATH)]
    if {$pathPresent} {
        set savedPath $::env(PATH)
    }
    try {
        foreach name [dict keys $saved] {
            unset ::env($name)
        }
        dict for {option name} $optins {
            if {[dict get $settings $option]} {
                set ::env($name) 1
            }
        }
        if {$compilerBin ne ""} {
            set ::env(PATH) [file nativename $compilerBin][expr {$pathPresent ? ";$savedPath" : ""}]
        }
        uplevel 1 $script
    } finally {
        foreach name [array names ::env] {
            foreach pattern $lanePatterns {
                if {[string match -nocase $pattern $name]} {
                    unset ::env($name)
                    break
                }
            }
        }
        dict for {name value} $saved {
            set ::env($name) $value
        }
        if {$pathPresent} {
            set ::env(PATH) $savedPath
        } else {
            unset -nocomplain ::env(PATH)
        }
    }
}

# The tested executable's identity: its --version and SHA-256.
proc ::gate::identify {runtime} {
    set result [run -timeout 1m -- $runtime --version]
    if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
        fail "cannot identify the tested executable: [file nativename $runtime]"
    }
    dict create version [string trim [encoding convertfrom utf-8 [dict get $result out]]] \
        sha256 [hash file sha256 $runtime]
}

proc ::gate::seconds {started} {
    format %.2f [expr {([clock milliseconds] - $started) / 1000.0}]
}

# Runs one step on this console; the bare host, when the step has one, is put
# in place before and deleted after. When identity is given, the tested
# executable must still have it afterwards.
proc ::gate::execute {step runtime identity} {
    set label [dict get $step label]
    puts "\n== $label =="
    flush stdout
    set started [clock milliseconds]
    set options {}
    if {[dict exists $step timeout]} {
        lappend options -timeout [dict get $step timeout]
    }
    set expect [expr {[dict exists $step expect] ? [dict get $step expect] : 0}]
    try {
        if {[dict exists $step bare]} {
            extractBare $runtime [dict get $step bare]
        }
        if {[catch {run -inherit {*}$options -- {*}[dict get $step argv]} result]} {
            fail "$label could not run: $result"
        }
    } finally {
        if {[dict exists $step bare]} {
            file delete [dict get $step bare]
        }
    }
    # run reports a nonzero exit as status error; a deadline or a kill always
    # fails the step.
    set exit [expr {[dict get $result exit] & 0xFFFFFFFF}]
    if {[dict get $result status] ni {ok error} || $exit != ($expect & 0xFFFFFFFF)} {
        fail "$label failed ([dict get $result status], exit code [format 0x%08X $exit])"
    }
    if {[dict size $identity] && [hash file sha256 $runtime] ne [dict get $identity sha256]} {
        fail "the tested executable changed during $label"
    }
    puts "PASS $label ([seconds $started]s)"
}

# The bare host is the packaged console basekit: the entry test's payload
# refusal runs it with nothing appended.
proc ::gate::extractBare {runtime path} {
    set mount gate-basekit-[pid]
    zipfs mount $runtime $mount
    try {
        file copy //zipfs:/$mount/basekit/console.exe $path
    } finally {
        zipfs unmount $mount
    }
}

# What the gate refuses to inherit: MACHTELD_WERROR=0 would build the runtime
# without -Werror (tools/buildlib.tcl).
proc ::gate::checkEnvironment {} {
    if {[info exists ::env(MACHTELD_WERROR)] && $::env(MACHTELD_WERROR) eq "0"} {
        fail "MACHTELD_WERROR=0 turns -Werror off; the gate builds and compiles with it on"
    }
}

proc ::gate::main {argv} {
    variable root
    set started [clock milliseconds]
    set settings [parse $argv]
    checkEnvironment
    dict set settings runtime [set runtime [file normalize [dict get $settings runtime]]]
    dict set settings cache [set cache [file normalize [dict get $settings cache]]]
    if {[needs $settings msys]} {
        dict set settings msys [::boot::msysRoot [dict get $settings msys]]
        set gcc [file join [dict get $settings msys] ucrt64 bin gcc.exe]
        if {![file isfile $gcc]} {
            fail "MSYS2 gcc not found: [file nativename $gcc]"
        }
    }
    puts "gate: groups [join [dict get $settings groups] {, }][expr {[dict get $settings build] ? {, after the release build} : {}}]"
    if {[dict get $settings build]} {
        execute [dict create label "release build" argv [list [info nameofexecutable] \
            [file join $root tools release.tcl] --output $runtime --cache $cache --msys [dict get $settings msys]]] \
            $runtime {}
    }
    if {[needs $settings tclsh]} {
        set tclsh [file join $cache prefix bin tclsh90s.exe]
        if {![file isfile $tclsh]} {
            fail "the dependency cache's static tclsh not found: [file nativename $tclsh]"
        }
    }
    set identity {}
    if {[needs $settings runtime]} {
        if {![file isfile $runtime]} {
            fail "runtime not found: [file nativename $runtime]; build it first (tools/release.tcl), or run the gate without --group"
        }
        set identity [identify $runtime]
        puts "tested executable: [file nativename $runtime]"
        puts "  version [dict get $identity version], SHA-256 [dict get $identity sha256]"
    }
    file mkdir [file join $root out test]
    set compilerBin [expr {[needs $settings msys] ? [file join [dict get $settings msys] ucrt64 bin] : ""}]
    set steps [plan $settings]
    withLaneEnvironment $settings $compilerBin {
        foreach step $steps {
            execute $step $runtime $identity
        }
    }
    if {[dict size $identity]} {
        puts "\ntested executable unchanged: version [dict get $identity version], SHA-256 [dict get $identity sha256]"
    }
    puts "[llength $steps] steps in [seconds $started]s"
    puts "ALL TEST LANES PASSED"
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
