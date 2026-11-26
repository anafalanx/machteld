package require machteld 0.21

# tools/gate.tcl -- the release gate. With no --group it builds the runtime
# (unless --skip-build) and runs the default groups on it. --group release
# explicitly requests the same gate. Other named groups test an existing
# executable in group order. --runtime selects the file for a test-only run.
# A building gate promotes its private build to out/machteld.exe after all
# selected tests have passed on those exact bytes.
#
#     machteld.exe tools/gate.tcl ?--group NAME ...? ?--runtime EXE? ?--cache DIR?
#         ?--msys DIR? ?--skip-build? ?--public-tls? ?--interactive-pty? ?--cloud?
#         ?--interactive-gui? ?--progress-jsonl FILE?
#
# The groups (the candidate's tools/test.ps1 groups, machteld 8bcc1ec):
#
#   fast                 no compiler and no MSYS2: reference coverage, version
#                        claims and their regressions, build identity, the
#                        reference serializer, this gate's own test, and the
#                        runtime lanes that need no fixture (filesystem,
#                        runtime services, protocol, background jobs, app archives, GUI model, embedded
#                        reference, README examples, JSONTestSuite, native
#                        adversarial inputs and filesystem boundaries)
#   integration          the C fixtures, the command-line golden vectors, the
#                        development cache, and the process, store, native and
#                        streaming-bounds lanes
#   packaging            the runtime's build identity, entry, package and
#                        publication, VERSIONINFO, 0.21 executable compatibility,
#                        archive inventories, relocated examples and the Tcl
#                        application corpus in source, archive and wrapped form
#   native-validation    the candidate's group: native lifetime with the
#                        telemetry probe; bounded worker scaling (every child
#                        live and closed, 128 ordered pool replies and the
#                        handle bound at widths 1, 8 and 32; its timings are
#                        printed, not gated); the undefined-behavior-trapped
#                        drivers of tools/native-analysis.tcl after their trap
#                        canary, each under a deadline: command line and its
#                        allocation failures, Unicode, the JSON corpus and
#                        adversarial inputs, the native filesystem and SQLite
#                        boundaries and the hash boundary; and last the
#                        full harness of tools/native-analysis.tcl: GCC's
#                        analyzer over src/*.c, the sanitizer probes, the
#                        trapped drivers again, the Tk index formatter and
#                        Unicode output paths, with a report under
#                        out/native-analysis-<id>/
#   reference-generator  two cold reference generations, byte for byte
#   release              alone: the build, then every group above (the default)
#   audio-device         explicit hardware qualification of an existing runtime:
#                        silent PCM and local HLS playback on a Windows endpoint
#
# Off by default, each behind its own option, none of it in a release run:
#
#   --public-tls         (integration or release) the native lane's public TLS
#                        checks, which reach the network
#   --cloud              (integration or release) register a temporary NTFS
#                        Cloud Files provider using the x64 Windows SDK
#   --interactive-pty    (integration or release) the process lane's console I/O
#   --interactive-gui    the Tk archive, GUI widgets and the SQLite lookup
#                        open windows for attended checks
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
source -encoding utf-8 [file join $::gate::root tools native-analysis.tcl]

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
        tls 0 pty 0 gui 0 cloud 0 progress-jsonl "" progress ""]
    set requested {}
    set given {}
    while {[llength $argv]} {
        set argv [lassign $argv option]
        switch -- $option {
            --group - --runtime - --cache - --msys - --progress-jsonl {
                if {![llength $argv]} {
                    fail "$option needs a value"
                }
                set argv [lassign $argv value]
                if {$option eq "--group"} {
                    lappend requested $value
                } else {
                    dict set settings [string range $option 2 end] $value
                    lappend given $option
                }
            }
            --skip-build {dict set settings skipBuild 1}
            --public-tls {dict set settings tls 1}
            --cloud {dict set settings cloud 1}
            --interactive-pty {dict set settings pty 1}
            --interactive-gui {dict set settings gui 1}
            default {fail "unknown option $option"}
        }
    }
    set selected {}
    set known [concat $groups audio-device release]
    foreach name $requested {
        if {$name ni $known} {
            fail "unknown group $name (known: [join $known {, }])"
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
    # Building gates publish only to the checkout's qualified output.
    if {[dict get $settings build] && "--runtime" in $given} {
        fail "--runtime selects an existing executable for testing: add --skip-build or select a test group other than release"
    }
    set chosen [dict get $settings groups]
    if {([dict get $settings tls] || [dict get $settings pty] || [dict get $settings cloud]) && "integration" ni $chosen} {
        fail "--public-tls, --interactive-pty and --cloud need the integration or release group"
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
            expr {[dict get $settings gui] || [anyOf {fast integration packaging native-validation audio-device} $chosen]}
        }
        msys {
            expr {[dict get $settings build] || [dict get $settings gui] ||
                [anyOf {integration packaging native-validation} $chosen]}
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
# default), timeout, extract (payload paths of the runtime under test and the
# files they are copied to before the step) and cleanup (what is deleted after
# it). A step already planned (the same argv) is not planned twice.
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
            audio-device {
                addLane steps $runtime audio-device "WASAPI device lifecycle (silence)" audio_test.tcl --device
                addLane steps $runtime audio-device "HLS through a Windows audio endpoint (silence)" hls_test.tcl --device
            }
            fast {
                addStep steps fast "reference coverage" [list $tclsh [file join $root tools check_reference.tcl]]
                addStep steps fast "version consistency" [list $tclsh [file join $root tools check_version.tcl]]
                addStep steps fast "version-check regressions" [list $tclsh [file join $test check_version_test.tcl]]
                addStep steps fast "build identity" [list $tclsh [file join $test build_identity_test.tcl]]
                addStep steps fast "build hash diagnostics" [list $driver [file join $test repro_report_test.tcl]]
                addStep steps fast "reference serializer" [list $driver [file join $test reference_serializer_test.tcl] --tclsh $tclsh]
                addStep steps fast "gate groups and environment" [list $driver [file join $test gate_test.tcl]]
                addLane steps $runtime fast filesystem filesystem_test.tcl
                addLane steps $runtime fast "runtime services" runtime_test.tcl
                addLane steps $runtime fast protocol protocol_test.tcl
                addLane steps $runtime fast "background jobs" job_test.tcl
                addLane steps $runtime fast "Tcl scripts and app archives" archive_test.tcl
                addLane steps $runtime fast "same-application workers and archive replacement" app_launch_test.tcl
                addLane steps $runtime fast "atomic file publication" publish_test.tcl
                addLane steps $runtime fast "loopback HTTP server" httpd_test.tcl
                addLane steps $runtime fast "cross-process file locks" lock_test.tcl
                addLane steps $runtime fast "clipboard ownership query" clipboard_test.tcl
                addLane steps $runtime fast "desktop arguments and document paths" desktop_test.tcl
                addLane steps $runtime fast "browser session boundaries" browser_test.tcl
                addLane steps $runtime fast "SQLite Tcl interface" sqlite3_test.tcl
                addLane steps $runtime fast "Graphviz layout and drawing" graphviz_test.tcl
                addLane steps $runtime fast "XXH3-64 catalog checksums" xxh3_test.tcl
                addLane steps $runtime fast "Directory metadata and local-only reads" localfiles_test.tcl
                addLane steps $runtime fast "Text encoding detector" encoding_test.tcl
                addLane steps $runtime fast "Windows network diagnostics" network_test.tcl
                addLane steps $runtime fast "UDP datagrams and event delivery" udp_test.tcl
                addLane steps $runtime fast "GUI model" gui_model_test.tcl
                addLane steps $runtime fast "embedded reference" reference_test.tcl
                addLane steps $runtime fast "README examples" documentation_examples_test.tcl
                addLane steps $runtime fast JSONTestSuite json_test.tcl
                addLane steps $runtime fast "native adversarial inputs" native_adversarial_test.tcl
                addLane steps $runtime fast "native filesystem boundaries" native_filesystem_test.tcl
            }
            integration {
                if {[dict get $settings cloud]} {
                    set provider [file join $out cloud_files_provider.exe]
                    set object [file join $out cloud_files_provider.obj]
                    addStep steps integration "Windows SDK cloud provider" [list cl.exe /nologo /W4 /WX /O2 \
                        /Fe:[file nativename $provider] /Fo:[file nativename $object] \
                        [file join $test fixtures cloud_files_provider.c] cldapi.lib]
                    addLane steps $runtime integration "Cloud Files zero-fetch acceptance" localfiles_test.tcl --cloud $provider
                }
                set httpFixture [file join $out http_fixture.exe]
                set sqliteObject [file join $out sqlite3-test.o]
                set lockFixture [file join $out sqlite_lock_fixture.exe]
                set cmdline [file join $out cmdline_test.exe]
                set sqlite [file join $cache sqlite]
                addStep steps integration "fixture http_fixture.c" [list $gcc {*}$strict -municode \
                    [file join $test fixtures http_fixture.c] -lws2_32 -o $httpFixture]
                set ntsServer [file join $out nts_server.exe]
                addStep steps integration "independent OpenSSL NTS peer" [list $gcc {*}$strict \
                    [file join $test fixtures nts_server.c] -lssl -lcrypto -lws2_32 -o $ntsServer]
                addLane steps $runtime integration "authenticated NTS time" nts_test.tcl $ntsServer
                addStep steps integration "SQLite test object" [list $gcc -O2 -w -DSQLITE_THREADSAFE=1 \
                    -DSQLITE_OMIT_LOAD_EXTENSION -c [file join $sqlite sqlite3.c] -o $sqliteObject]
                addStep steps integration "fixture sqlite_lock_fixture.c" [list $gcc {*}$strict -municode \
                    [file join $test fixtures sqlite_lock_fixture.c] -I $sqlite $sqliteObject -o $lockFixture]
                addStep steps integration "fixture cmdline_test.c" [list $gcc {*}$strict -I [file join $root src] \
                    [file join $test cmdline_test.c] [file join $root src winjob_cmdline.c] -o $cmdline]
                addStep steps integration "command-line golden vectors" [list $cmdline]
                set privateRunner [file join $out desktop_runner.exe]
                set windowFixture [file join $out window_fixture.exe]
                set catalogFixture [file join $out desktop_catalog.dll]
                addStep steps integration "fixture desktop_runner.c" [list $gcc {*}$strict -municode \
                    [file join $test fixtures desktop_runner.c] -luser32 -o $privateRunner]
                addStep steps integration "fixture window_fixture.c" [list $gcc {*}$strict -municode -mwindows \
                    [file join $test fixtures window_fixture.c] -luser32 -lole32 -luuid -o $windowFixture]
                addStep steps integration "fixture desktop_catalog.c" [list $gcc {*}$strict -shared -DUSE_TCL_STUBS -DUSE_TK_STUBS \
                    -I [file join $cache prefix include] [file join $test fixtures desktop_catalog.c] \
                    [file join $root src wintext.c] [file join $cache prefix lib libtkstub.a] \
                    [file join $cache prefix lib libtclstub.a] -lshell32 -lole32 -luuid -luser32 -lgdi32 -o $catalogFixture]
                addStep steps integration "isolated standalone application windows and icons" [list $privateRunner --timeout-seconds 300 $runtime \
                    [file join $test wrap_test.tcl] $catalogFixture] timeout 360s
                addStep steps integration "isolated desktop selection" [list $privateRunner $runtime \
                    [file join $test desktop_test.tcl] $windowFixture $catalogFixture] timeout 120s
                addStep steps integration "isolated child window startup and callbacks" [list $privateRunner $runtime \
                    [file join $test child_window_test.tcl] $windowFixture] timeout 90s
                addStep steps integration "isolated browser lifecycle" [list $privateRunner $runtime \
                    [file join $test browser_test.tcl]] timeout 120s
                addStep steps integration "isolated shortcut to a relocated archive" [list $privateRunner $runtime \
                    [file join $test archive_shortcut_test.tcl] $windowFixture] timeout 90s
                set ffiDependency [file join $out machteld_cffi_dependency.dll]
                set ffiFixture [file join $out machteld_cffi_fixture.dll]
                set ffiImport [file join $out libmachteld_cffi_dependency.a]
                addStep steps integration "fixture cffi_dependency.c" [list $gcc {*}$strict -shared \
                    [file join $test fixtures cffi_dependency.c] -Wl,--out-implib,$ffiImport -o $ffiDependency]
                addStep steps integration "fixture cffi_fixture.c" [list $gcc {*}$strict -shared \
                    [file join $test fixtures cffi_fixture.c] $ffiImport -o $ffiFixture]
                addLane steps $runtime integration "synchronous foreign calls" cffi_test.tcl $ffiFixture $ffiDependency
                addStep steps integration "development cache" [list $driver [file join $test dev_cache_test.tcl] --msys $msys]
                addLane steps $runtime integration process process_test.tcl $processFixture
                addLane steps $runtime integration "child notifications" child_notifications_test.tcl $processFixture
                addLane steps $runtime integration store store_test.tcl $lockFixture
                addLane steps $runtime integration native native_test.tcl $httpFixture $processFixture
                addLane steps $runtime integration "asynchronous HTTP response streams" http_stream_test.tcl
                addLane steps $runtime integration "MP3, AAC and HE-AAC PCM" audio_test.tcl
                addLane steps $runtime integration "rolling HLS audio" hls_test.tcl
                addLane steps $runtime integration "streaming bounds" streaming_bounds_test.tcl $processFixture
            }
            packaging {
                addStep steps packaging "build identity of the runtime" [list $tclsh [file join $test build_identity_test.tcl] $runtime]
                addStep steps packaging entry [list $driver [file join $test entry_test.tcl] $runtime \
                    --fixture $processFixture]
                addStep steps packaging "package and publication" [list $driver [file join $test package_test.tcl] --tclsh $tclsh]
                addStep steps packaging VERSIONINFO [list $driver [file join $test version_resource_test.tcl] $runtime --cache $cache]
                addLane steps $runtime packaging "legacy application compatibility" legacy_wrapper_test.tcl $driver
                addLane steps $runtime packaging "Tcl application corpus" application_corpus_test.tcl
                addLane steps $runtime packaging "archive inventory" pack_inventory_test.tcl
                addLane steps $runtime packaging "standalone wrapped applications" wrap_test.tcl
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
                # Its checks gate; only its timings are observations.
                addLane steps $runtime native-validation "native scaling" native_scaling_test.tcl $probe $processFixture
                foreach step [::na::trappedSteps [::na::layout $cache] $gcc $out $runtime] {
                    addStep steps native-validation [dict get $step label] [dict get $step argv] {*}[dict remove $step label argv]
                }
                # The whole harness, as the candidate's group ran it: it runs
                # the trapped drivers once more, under its own source-drift
                # check and into its own report.
                addStep steps native-validation "native analysis (full harness)" [list $driver \
                    [file join $root tools native-analysis.tcl] --cache $cache --msys $msys]
            }
            reference-generator {
                addStep steps reference-generator "reference generator" [list $driver \
                    [file join $test reference_generator_test.tcl] --cache $cache --tclsh $tclsh]
            }
        }
    }
    if {[dict get $settings gui]} {
        set windowFixture [file join $out window_fixture.exe]
        addStep steps interactive "fixture window_fixture.c" [list $gcc {*}$strict -municode -mwindows \
            [file join $test fixtures window_fixture.c] -luser32 -lole32 -luuid -o $windowFixture]
        addLane steps $runtime interactive "attended child window" child_window_test.tcl $windowFixture
        addLane steps $runtime interactive "Graphviz Tk table selection" graphviz_tk_test.tcl
        addLane steps $runtime interactive "desktop window selection" desktop_test.tcl --windows $windowFixture
        addLane steps $runtime interactive "UDP during Tk event delivery" udp_test.tcl --tk
        addLane steps $runtime interactive "Direct2D and Direct3D Tk rendering and pre-present readback" surface_test.tcl
        set displays [file join $out surface_displays.exe]
        addStep steps interactive "fixture surface_displays.c" [list $gcc {*}$strict \
            [file join $test fixtures surface_displays.c] -luser32 -lshcore -o $displays]
        addLane steps $runtime interactive "Tk graphics on each connected monitor" surface_dpi_test.tcl $displays
        addLane steps $runtime interactive "per-monitor-aware Tk graphics" surface_dpi_test.tcl $displays --per-monitor
        addLane steps $runtime interactive "Tk app archive" archive_test.tcl --tk
        addLane steps $runtime interactive "packaged SQLite lookup" sqlite_lookup_gui_test.tcl
        addLane steps $runtime interactive "GUI widgets (opens windows)" gui_widget_test.tcl
        addLane steps $runtime interactive "Tk loopback HTTP server" httpd_test.tcl --tk
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

# Runs one step on this console: what it extracts from the runtime under test
# is put in place first, and what it cleans up is deleted after it, passed or
# failed. When identity is given, the tested executable must still have it.
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
        if {[catch {run -inherit {*}$options -- {*}[dict get $step argv]} result]} {
            fail "$label could not run: $result"
        }
    } finally {
        if {[dict exists $step cleanup]} {
            foreach path [dict get $step cleanup] {
                file delete -force -- $path
            }
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

# What the gate refuses to inherit: MACHTELD_WERROR=0 would build the runtime
# without -Werror (tools/buildlib.tcl).
proc ::gate::checkEnvironment {} {
    if {[info exists ::env(MACHTELD_WERROR)] && $::env(MACHTELD_WERROR) eq "0"} {
        fail "MACHTELD_WERROR=0 turns -Werror off; the gate builds and compiles with it on"
    }
}

proc ::gate::progressEvent {channel event kind name status {elapsed ""}} {
    set record [dict create schema [expr {1}] at_ms [clock milliseconds] event $event \
        kind $kind name $name status $status]
    if {$elapsed ne ""} {dict set record elapsed_ms $elapsed}
    puts $channel [json encode -dict $record]
    flush $channel
}

# Keep the step executor replaceable for private-desktop console lanes. Emit
# the finish only after execution and preserve Tcl error options for callers.
proc ::gate::withProgress {channel kind name script} {
    if {$channel eq ""} {return [uplevel 1 $script]}
    set started [clock clicks -milliseconds]
    progressEvent $channel start $kind $name running
    set code [catch {uplevel 1 $script} result options]
    progressEvent $channel finish $kind $name [expr {$code ? "failed" : "passed"}] \
        [expr {max(0,[clock clicks -milliseconds]-$started)}]
    return -options $options $result
}

proc ::gate::qualify {settings} {
    variable root
    set runtime [dict get $settings runtime]
    if {[needs $settings tclsh]} {
        set tclsh [file join [dict get $settings cache] prefix bin tclsh90s.exe]
        if {![file isfile $tclsh]} {
            fail "the dependency cache's static tclsh not found: [file nativename $tclsh]"
        }
    }
    set identity {}
    if {[needs $settings runtime]} {
        if {![file isfile $runtime]} {
            fail "runtime not found: [file nativename $runtime]; use --runtime to select an existing executable, or run the gate without --group or --skip-build to build its default"
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
            withProgress [dict get $settings progress] step [dict get $step label] {
                execute $step $runtime $identity
            }
        }
    }
    if {[dict size $identity]} {
        if {[hash file sha256 $runtime] ne [dict get $identity sha256]} {
            fail "the tested executable changed before qualification finished"
        }
        puts "\ntested executable unchanged: version [dict get $identity version], SHA-256 [dict get $identity sha256]"
    }
    return [llength $steps]
}

proc ::gate::main {argv} {
    set settings [parse $argv]
    set path [dict get $settings progress-jsonl]
    if {$path eq ""} {return [runGate $settings]}
    # A new file keeps simultaneous and previous qualification evidence intact.
    if {[catch {open $path {WRONLY CREAT EXCL}} channel]} {
        fail "cannot create progress log [file nativename $path]: $channel"
    }
    try {
        fconfigure $channel -encoding utf-8 -translation lf
        dict set settings progress $channel
        withProgress $channel suite gate {runGate $settings}
    } finally {close $channel}
}

proc ::gate::runGate {settings} {
    variable root
    set started [clock milliseconds]
    checkEnvironment
    set output [file normalize [dict get $settings runtime]]
    dict set settings runtime $output
    dict set settings cache [file normalize [dict get $settings cache]]
    set lock ""
    if {[needs $settings msys]} {
        dict set settings msys [::boot::msysRoot [dict get $settings msys]]
        set gcc [file join [dict get $settings msys] ucrt64 bin gcc.exe]
        if {![file isfile $gcc]} {
            fail "MSYS2 gcc not found: [file nativename $gcc]"
        }
        # Compiler lanes share out/test. A second release must also never
        # overwrite a later checkout qualification with an older candidate.
        set lock [file join $root out gate.lock]
        if {[catch {::machteld::devcache::lock $lock} why]} { fail $why }
    }
    set stage ""
    try {
        puts "gate: groups [join [dict get $settings groups] {, }][expr {[dict get $settings build] ? {, after the release build} : {}}]"
        if {[dict get $settings build]} {
            set stage [file tempdir [file join [file dirname $output] gate]]
            set candidate [file join $stage machteld.exe]
            dict set settings runtime $candidate
            set buildStep [dict create label "release build" argv [list [info nameofexecutable] \
                [file join $root tools release.tcl] --output $candidate --cache [dict get $settings cache] \
                --msys [dict get $settings msys]]]
            withProgress [dict get $settings progress] step "release build" {execute $buildStep $candidate {}}
        }
        set count [qualify $settings]
        if {$stage ne ""} {
            if {[catch {::machteld::Publish $candidate $output} why]} {
                fail "cannot publish the qualified executable to [file nativename $output]: $why"
            }
            puts "qualified executable: [file nativename $output]"
        }
    } finally {
        # Never recurse into other tools' leftovers or sweep a previous run.
        # Preserve the cause of a build, test or publication failure.
        if {$stage ne "" && [catch {
            file delete -- $candidate
            file delete -- $stage
        } why]} {
            puts stderr "gate: could not clean [file nativename $stage]: $why"
        }
        if {$lock ne "" && [catch {::machteld::devcache::unlock $lock} why]} {
            puts stderr "gate: could not release [file nativename $lock]: $why"
        }
    }
    puts "$count steps in [seconds $started]s"
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
