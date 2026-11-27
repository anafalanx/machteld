package require machteld 0.21

# test/gate_test.tcl -- the gate's own choices, checked with disposable lanes:
# how --group selections expand and which options each needs; which steps each
# group plans (fixtures only where they are used, the opt-in lanes only behind
# their options, a shared step once); the lanes' environment (inherited opt-ins
# and overlays removed, only the requested ones set, the caller's environment
# back after success and after failure); and the tested executable's identity
# held through every step, and publication of qualified bytes only.
#
#     machteld.exe test/gate_test.tcl
#
# Runs on the build runtime, as the gate does. The Tcl port of
# test/test_groups_test.ps1 (machteld 8bcc1ec), which read tools/test.ps1's
# functions out of its syntax tree; here the gate's procs are called directly.

set root [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $root tools gate.tcl]

set checks 0
set failures 0
proc check {name condition {detail ""}} {
    incr ::checks
    if {$condition} {
        puts "ok   $name"
    } else {
        incr ::failures
        puts "FAIL $name $detail"
    }
}
proc refused {argv pattern} {
    expr {[catch {::gate::parse $argv} message options] &&
        [dict get $options -errorcode] eq {GATE fail} && [string match $pattern $message]}
}
proc settings {argv} {
    set settings [::gate::parse $argv]
    dict set settings msys C:/fake-msys
    return $settings
}
proc labels {steps} {
    lmap step $steps {dict get $step label}
}
proc compiled {steps} {
    lmap step $steps {
        if {[file tail [lindex [dict get $step argv] 0]] ne "gcc.exe"} continue
        dict get $step label
    }
}
proc scripts {steps} {
    lmap step $steps {
        if {[llength [dict get $step argv]] < 2} continue
        set script [lindex [dict get $step argv] 1]
        if {![string match *.tcl $script]} continue
        file tail $script
    }
}
proc writeText {path text} {
    file mkdir [file dirname $path]
    set channel [open $path wb]
    puts -nonewline $channel [encoding convertto utf-8 $text]
    close $channel
}

# ---- groups and options ----

set all {fast integration packaging native-validation reference-generator}
set default [::gate::parse {}]
check {no --group runs every default group after the release build} \
    [expr {[dict get $default groups] eq $all && [dict get $default release] && [dict get $default build]}]
set skip [::gate::parse {--skip-build}]
check {--skip-build keeps every group and drops the build} \
    [expr {[dict get $skip groups] eq $all && ![dict get $skip build]}]
set release [::gate::parse {--group release}]
check {--group release is the default spelled out} \
    [expr {[dict get $release groups] eq $all && [dict get $release build]}]
check {release must be selected alone} [refused {--group release --group fast} {*release must be selected alone*}]
set named [::gate::parse {--group packaging --group fast --group packaging}]
check {named groups run in the order given, once each, and never build} \
    [expr {[dict get $named groups] eq {packaging fast} && ![dict get $named build] && ![dict get $named release]}]
check {an unknown group is refused} [refused {--group slow} {*unknown group slow*}]
check {an unknown option is refused} [refused {--fast} {*unknown option --fast*}]
check {--group needs a value} [refused {--group} {*--group needs a value*}]
foreach option {--public-tls --interactive-pty --cloud} {
    check "$option needs the integration or release group" \
        [expr {[refused [list --group fast $option] {*need the integration or release group*}] &&
            ![catch {::gate::parse [list --group integration $option]}] &&
            ![catch {::gate::parse [list $option]}]}]
}
check {the scaling lane and the full native analysis need no option: they are native validation's own} \
    [expr {[refused {--native-scaling} {*unknown option --native-scaling*}] &&
        [refused {--native-analysis} {*unknown option --native-analysis*}]}]
set optins [::gate::parse {--group integration --public-tls --interactive-gui}]
check {each option records only itself} \
    [expr {[dict get $optins tls] && ![dict get $optins pty] && [dict get $optins gui]}]
# Only the checkout's qualified name may be promoted by a building gate.
set signed C:/release/signed/machteld.exe
check {the qualified output defaults to out/machteld.exe} \
    [expr {[dict get $default runtime] eq [file join $root out machteld.exe]}]
check {--runtime is refused for a building gate} \
    [expr {[refused [list --runtime $signed] {*--runtime*existing executable*--skip-build*}] &&
        [refused [list --group release --runtime $signed] {*--runtime*existing executable*--skip-build*}] &&
        [refused [list --runtime $signed --interactive-gui] {*--runtime*existing executable*--skip-build*}]}]
set asIs [::gate::parse [list --skip-build --runtime $signed]]
set grouped [::gate::parse [list --group fast --runtime $signed]]
check {--runtime with --skip-build or --group tests that executable as it is} \
    [expr {![dict get $asIs build] && [dict get $asIs runtime] eq $signed && [dict get $asIs groups] eq $all &&
        ![dict get $grouped build] && [dict get $grouped runtime] eq $signed}]

# ---- what each group needs and plans ----

set fast [settings {--group fast}]
check {the fast group needs the runtime and tclsh but no MSYS2} \
    [expr {[::gate::needs $fast runtime] && [::gate::needs $fast tclsh] && ![::gate::needs $fast msys]}]
set generator [settings {--group reference-generator}]
check {the reference-generator group needs neither the runtime nor MSYS2} \
    [expr {![::gate::needs $generator runtime] && ![::gate::needs $generator msys] && [::gate::needs $generator tclsh]}]
check {the release build needs MSYS2} [::gate::needs [settings {}] msys]
set desktop [settings {--group reference-generator --interactive-gui}]
check {--interactive-gui needs the runtime and fixture compiler} \
    [expr {[::gate::needs $desktop runtime] && [::gate::needs $desktop msys]}]

check {the fast group compiles nothing} [expr {[compiled [::gate::plan $fast]] eq {}}]
check {the fast group tests script and archive launch} [expr {"archive_test.tcl" in [scripts [::gate::plan $fast]]}]
check {the integration group compiles its own fixtures and the process fixture} \
    [expr {[compiled [::gate::plan [settings {--group integration}]]] eq [list \
        {fixture process_fixture.c} {fixture http_fixture.c} {independent OpenSSL NTS peer} {SQLite test object} \
        {fixture sqlite_lock_fixture.c} {fixture cmdline_test.c} \
        {fixture desktop_runner.c} {fixture window_fixture.c} {fixture desktop_catalog.c} \
        {fixture cffi_dependency.c} {fixture cffi_fixture.c}]}]
check {the packaging group compiles only the process fixture} \
    [expr {[compiled [::gate::plan [settings {--group packaging}]]] eq {{fixture process_fixture.c}}}]
check {the release packaging group verifies standalone wrapping as well as legacy compatibility} \
    [expr {"wrap_test.tcl" in [scripts [::gate::plan [settings {--group packaging}]]] &&
        "legacy_wrapper_test.tcl" in [scripts [::gate::plan [settings {--group packaging}]]]}]
set nvPlan [::gate::plan [settings {--group native-validation}]]
check {the native-validation group compiles the process fixture, the telemetry probe and the trapped drivers} \
    [expr {[lrange [compiled $nvPlan] 0 2] eq {{fixture process_fixture.c} {fixture native_probe.c} {UB-trap canary}} &&
        [llength [lsearch -all [compiled $nvPlan] {trapped *: compile}]] == 15 &&
        {trapped PCM output lifetime} in [labels $nvPlan]}]
check {the reference-generator group compiles nothing} \
    [expr {[compiled [::gate::plan $generator]] eq {}}]

set releasePlan [::gate::plan [settings {}]]
set releaseLabels [labels $releasePlan]
set import [lindex $releasePlan [lsearch -exact $releaseLabels {typed colleague import}]]
check {the worked colleague import runs once in packaging on the candidate} [expr {
    [llength [lsearch -all -exact [scripts $releasePlan] typed_import_test.tcl]] == 1 &&
        [dict get $import group] eq "packaging" && [dict get $import argv] eq
        [list [dict get $default runtime] [file join $root test typed_import_test.tcl]]}]
proc compilerSuites {steps group runtime} {
    set suites {}
    foreach step $steps {
        if {[dict get $step group] ne $group} continue
        lassign [dict get $step argv] exe path
        if {![regexp {^application_compiler(?:_(.+))?_test\.tcl$} [file tail $path] -> suite]} continue
        if {$exe ne $runtime} {error "compiler suite selected the wrong runtime: $exe"}
        if {$suite eq ""} {set suite core}
        lappend suites [list $suite {*}[lrange [dict get $step argv] 2 end]]
    }
    return [lsort $suites]
}
set candidate [dict get $default runtime]
set direct {alias decode diagnostics extern group interpolation iteration text}
set packed {archive {examples -pack} host {io -pack} {migration -pack} {project -pack} reference {sql -pack} {temporal -pack} {transaction -pack} {zone -pack}}
check {fast runs in-process application compiler suites on the candidate} \
    [expr {[compilerSuites $releasePlan fast $candidate] eq {core decimal distinct map semantics}}]
check {integration alone runs the compiler's child-process and direct project, I/O, example and SQL tests} \
    [expr {[compilerSuites [::gate::plan [settings {--group integration}]] integration $candidate] eq
        [lsort [concat $direct {project io examples sql transaction migration temporal zone}]]}]
check {packaging runs the compiler archive and the packed project, I/O, example and SQL cases} \
    [expr {[compilerSuites [::gate::plan [settings {--group packaging}]] packaging $candidate] eq $packed}]
foreach plan [list $releasePlan [::gate::plan [settings {--group packaging --group integration}]]] {
    check {selecting both groups runs the direct cases just once inside each packed suite} \
        [expr {[compilerSuites $plan integration $candidate] eq $direct &&
            [compilerSuites $plan packaging $candidate] eq $packed}]
}
set corpus [lindex $releasePlan [lsearch -exact $releaseLabels {Tcl application corpus}]]
check {the release runs the unfiltered Tcl application corpus once on the candidate} [expr {
    [llength [lsearch -all -exact [scripts $releasePlan] application_corpus_test.tcl]] == 1 &&
    $corpus ne {} && [dict get $corpus group] eq "packaging" &&
    [dict get $corpus argv] eq [list [dict get $default runtime] [file join $root test application_corpus_test.tcl]]}]
set shortcutStep [lindex $releasePlan [lsearch -exact $releaseLabels {isolated shortcut to a relocated archive}]]
check {the relocated archive shortcut runs exclusively through the private desktop runner} [expr {
    [lmap arg [dict get $shortcutStep argv] {file tail $arg}] eq
    {desktop_runner.exe machteld.exe archive_shortcut_test.tcl window_fixture.exe}}]
set windowStep [lindex $releasePlan [lsearch -exact $releaseLabels {isolated child window startup and callbacks}]]
set wrapWindowStep [lindex $releasePlan [lsearch -exact $releaseLabels {isolated standalone application windows and icons}]]
check {wrapped application window and icon checks use the release's private desktop} [expr {
    [lmap arg [dict get $wrapWindowStep argv] {file tail $arg}] eq
    {desktop_runner.exe --timeout-seconds 300 machteld.exe wrap_test.tcl desktop_catalog.dll}}]
check {the release exercises supervised child window startup and Tk callbacks on its private desktop} [expr {
    [lmap arg [dict get $windowStep argv] {file tail $arg}] eq
    {desktop_runner.exe machteld.exe child_window_test.tcl window_fixture.exe}}]
check {release compiles the process fixture once, first} \
    [expr {[lsearch -all $releaseLabels {fixture process_fixture.c}] eq {0}}]
check {release plans the groups in order} \
    [expr {[lsort -unique [lmap step $releasePlan {dict get $step group}]] eq
            [lsort -unique [concat fixtures $all]] &&
        [lsearch -exact $releaseLabels protocol] < [lsearch -exact $releaseLabels process] &&
        [lsearch -exact $releaseLabels process] < [lsearch -exact $releaseLabels entry] &&
        [lsearch -exact $releaseLabels entry] < [lsearch -exact $releaseLabels {native lifecycle}] &&
        [lsearch -exact $releaseLabels {native lifecycle}] < [lsearch -exact $releaseLabels {reference generator}]}]
check {a step two groups share runs once} \
    [expr {[llength [lsearch -all $releaseLabels {native adversarial inputs}]] == 1 &&
        [dict get [lindex $releasePlan [lsearch -exact $releaseLabels {native adversarial inputs}]] group] eq "fast"}]
check {native validation plans the lifecycle lane with the probe and the process fixture} \
    [expr {"native_lifecycle_test.tcl" in [scripts [::gate::plan [settings {--group native-validation}]]]}]
# Native validation as the candidate's tools/test.ps1 defined it: the scaling
# lane after the lifecycle lane and the full analysis last, in every run of the
# group, the release's included.
set nvOrder [labels $nvPlan]
set at [lsearch -exact $nvOrder {native scaling}]
check {native validation runs the bounded scaling lane after the lifecycle lane, with the probe and the process fixture} \
    [expr {$at > 0 && $at == [lsearch -exact $nvOrder {native lifecycle}] + 1 &&
        [lmap word [lrange [dict get [lindex $nvPlan $at] argv] 1 end] {file tail $word}] eq
            {native_scaling_test.tcl native_probe.dll process_fixture.exe}}]
set analysis [lindex $nvPlan end]
check {native validation ends with the full native analysis, on the gate's cache and MSYS2} \
    [expr {[dict get $analysis label] eq "native analysis (full harness)" &&
        [lrange [dict get $analysis argv] 1 end] eq [list [file join $root tools native-analysis.tcl] \
            --cache [file normalize [file join $root .cache deps]] --msys C:/fake-msys]}]
check {release runs the scaling lane and the full native analysis, as the candidate's release did} \
    [expr {"native_scaling_test.tcl" in [scripts $releasePlan] && "native-analysis.tcl" in [scripts $releasePlan]}]

# The trapped drivers: the canary first, its two faults ending in
# STATUS_ILLEGAL_INSTRUCTION under a deadline, every driver compiled with the
# traps and -Werror, every boundary the candidate's analysis drove, and the
# identity primitives on basekits of the runtime under test.
set nvLabels [labels $nvPlan]
set faults [lmap step $nvPlan {if {![string match {UB-trap canary traps *} [dict get $step label]]} continue; set step}]
check {native validation shows the traps fire before any trapped driver runs} \
    [expr {[llength $faults] == 2 &&
        [lsearch -exact $nvLabels {UB-trap canary runs clean}] < [lsearch -exact $nvLabels {UB-trap canary traps overflow}] &&
        [lsearch -exact $nvLabels {UB-trap canary traps bounds}] < [lsearch -glob $nvLabels {trapped *}] &&
        [llength [lmap step $faults {
            if {[dict get $step expect] != 0xC000001D || ![dict exists $step timeout]} continue; set step}]] == 2}]
# Every trapped step runs under a deadline, as every invocation of the
# candidate's harness did (tools/native-analysis.ps1: 180 s, and 15 s for its
# negative canaries), and the gate's plan carries each one to run -timeout.
set trapped [::na::trappedSteps [::na::layout [file join $root .cache deps]] \
    C:/fake-msys/ucrt64/bin/gcc.exe [file join $root out test]]
set wrongDeadlines {}
foreach step $trapped {
    set want [expr {[string match {UB-trap canary traps *} [dict get $step label]] ? "30s" : "180s"}]
    if {![dict exists $step timeout] || [dict get $step timeout] ne $want} {
        lappend wrongDeadlines [dict get $step label]
    }
}
foreach step $nvPlan {
    if {[dict get $step label] in [labels $trapped] && ![dict exists $step timeout]} {
        lappend wrongDeadlines "planned without one: [dict get $step label]"
    }
}
check {every trapped step runs under a deadline, 180 s and 30 s for a fault the canary must trap, in the gate's plan too} \
    [expr {[llength $trapped] && ![llength $wrongDeadlines]}] $wrongDeadlines
set untrapped {}
foreach step $nvPlan {
    if {![string match {trapped *: compile} [dict get $step label]]} continue
    foreach flag {-Werror -fsanitize=undefined -fsanitize-undefined-trap-on-error} {
        if {$flag ni [dict get $step argv]} { lappend untrapped "[dict get $step label] $flag" }
    }
}
check {every trapped driver compiles with the undefined-behavior traps and -Werror} [expr {![llength $untrapped]}] $untrapped
set driven {}
foreach step $nvPlan {
    if {![string match {trapped *} [dict get $step label]] || [string match {*: compile} [dict get $step label]]} continue
    lappend driven [lmap word [lrange [dict get $step argv] 0 1] {file tail $word}]
}
check {the trapped drivers run the native, branding, audio, filesystem, encoding and networking boundaries} \
    [expr {$driven eq [list cmdline-trap.exe cmdline-allocation-trap.exe wintext-trap.exe \
        {identity-trap.exe identity_native_test.tcl} \
        {json-trap.exe json_test.tcl} {json-trap.exe native_adversarial_test.tcl} \
        native-boundary-trap.exe hash-boundary-trap.exe audio-output-trap.exe files-provider-trap.exe \
        {publish-recovery-trap.exe publish_recovery.tcl} \
        nts-crypto-trap.exe nts-lifetime-trap.exe udp-trap.exe network-trap.exe \
        {encoding-trap.exe system} {encoding-trap.exe missing} {encoding-trap.exe incomplete}]}] $driven
set guiPlan [::gate::plan [settings {--interactive-gui}]]
set audioSettings [::gate::parse {--group audio-device}]
set audioPlan [::gate::plan $audioSettings]
check {hardware playback alone needs the existing runtime and opens its endpoint with silence} \
    [expr {![dict get $audioSettings build] && [::gate::needs $audioSettings runtime] &&
        ![::gate::needs $audioSettings msys] && ![::gate::needs $audioSettings tclsh] &&
        [lmap step $audioPlan {lmap word [lrange [dict get $step argv] 1 end] {file tail $word}}] eq
        {{audio_test.tcl --device} {hls_test.tcl --device}}}]
foreach {mode normal} [list default $releasePlan hosted-GUI $guiPlan] {
    set media [lmap step $normal {
        set cmd [dict get $step argv]
        if {[file tail [lindex $cmd 1]] ni {audio_test.tcl hls_test.tcl}} continue
        lmap word [lrange $cmd 1 end] {file tail $word}
    }]
    check "the $mode gate requires the offline codec and HLS suites" \
        [expr {$media eq {audio_test.tcl hls_test.tcl}}] $media
}
set attended [lmap step $guiPlan {if {[dict get $step group] ne "interactive"} continue; set step}]
set archiveLane [lindex $attended [lsearch -exact [labels $attended] "Tk app archive"]]
check {the window-opening lanes run only behind --interactive-gui, last} \
    [expr {"child_window_test.tcl" ni [scripts $releasePlan] &&
        "child_window_test.tcl" in [scripts $guiPlan] &&
        "gui_widget_test.tcl" ni [scripts $releasePlan] &&
        "sqlite_lookup_gui_test.tcl" ni [scripts $releasePlan] &&
        "graphviz_test.tcl" in [scripts $releasePlan] &&
        "graphviz_tk_test.tcl" ni [scripts $releasePlan] && "graphviz_tk_test.tcl" in [scripts $guiPlan] &&
        "Tk app archive" ni $releaseLabels &&
        [lindex [dict get $archiveLane argv] end] eq "--tk" &&
        [lrange $guiPlan end-[expr {[llength $attended]-1}] end] eq $attended &&
        [lrange [scripts $attended] end-3 end] eq {archive_test.tcl sqlite_lookup_gui_test.tcl gui_widget_test.tcl httpd_test.tcl}}]
set missing {}
foreach step [concat $releasePlan [::gate::plan [settings {--interactive-gui}]]] {
    foreach word [dict get $step argv] {
        if {[string match [file join $root test]/* $word] || [string match [file join $root tools]/* $word]} {
            if {![file isfile $word]} {
                lappend missing $word
            }
        }
    }
}
check {every program and source the plan names exists} [expr {![llength $missing]}] $missing

# Every test program and C source under test/ is something the gate runs or
# compiles, behind an option or not, or is run by another test (named here
# with that test, which must name it).
set cloudPlan [::gate::plan [settings {--group integration --cloud}]]
set cloudBuild [lsearch -exact [labels $cloudPlan] {Windows SDK cloud provider}]
set cloudRun [lsearch -exact [labels $cloudPlan] {Cloud Files zero-fetch acceptance}]
check {the optional SDK lane builds the provider and passes it to the real Cloud Files test} \
    [expr {$cloudBuild >= 0 && $cloudRun == $cloudBuild + 1 &&
        {Windows SDK cloud provider} ni $releaseLabels && {Cloud Files zero-fetch acceptance} ni $releaseLabels &&
        [lindex [dict get [lindex $cloudPlan $cloudBuild] argv] 0] eq "cl.exe" &&
        [lmap word [lrange [dict get [lindex $cloudPlan $cloudRun] argv] end-2 end] {file tail $word}] eq
        {localfiles_test.tcl --cloud cloud_files_provider.exe}}]
set everything [concat $releasePlan $guiPlan $cloudPlan $audioPlan]
set named {}
foreach step $everything {
    foreach word [dict get $step argv] {
        dict set named [file tail $word] 1
    }
}
proc mentions {path name} {
    set channel [open $path rb]
    try { expr {[string first $name [read $channel]] >= 0} } finally { close $channel }
}
set inner [dict create gui_model_fairness_test.tcl test/gui_model_test.tcl \
    protocol_fairness_test.tcl test/protocol_test.tcl \
    application_qualification_test.tcl test/gate_test.tcl \
    tk_index_format_test.c tools/native-analysis.tcl]
set unwired {}
foreach path [lsort [concat [glob -directory [file join $root test] *_test.tcl *.c] \
        [glob -directory [file join $root test fixtures] *.c]]] {
    set name [file tail $path]
    if {[dict exists $named $name]} continue
    if {[dict exists $inner $name] && [mentions [file join $root {*}[split [dict get $inner $name] /]] $name]} continue
    lappend unwired $name
}
check {every test program and C source is run, compiled, or run by another test} [expr {![llength $unwired]}] $unwired

# ---- the lanes' environment ----

set laneNames {MACHTELD_TEST_PUBLIC_TLS MACHTELD_TEST_PTY_IO MACHTELD_WRAP_GUI_INTERACTIVE
    MACHTELD_TEST_WORKER_SOURCE MACHTELD_TEST_PIDFILE MACHTELD_WRAP_GUI_SELFTEST}
set saved {}
foreach name [concat $laneNames PATH] {
    if {[info exists ::env($name)]} {
        dict set saved $name $::env($name)
    }
}
proc present {} {
    lmap name $::laneNames {if {![info exists ::env($name)]} continue; set name}
}
proc sentinels {} {
    foreach name $::laneNames {
        set ::env($name) "C:/gate fixture/inherited $name"
    }
}
try {
    sentinels
    set none [dict create tls 0 pty 0 gui 0]
    ::gate::withLaneEnvironment $none "" {
        set inside [present]
        foreach name {MACHTELD_TEST_WORKER_SOURCE MACHTELD_TEST_PIDFILE} {
            set ::env($name) "test-owned override"
        }
    }
    check {lanes lose every inherited opt-in and overlay} [expr {$inside eq {}}] $inside
    check {the caller's values come back after a lane scope, its own overrides gone} \
        [expr {[lmap name $laneNames {set ::env($name)}] eq [lmap name $laneNames {string cat "C:/gate fixture/inherited " $name}]}]
    foreach {option name} {tls MACHTELD_TEST_PUBLIC_TLS pty MACHTELD_TEST_PTY_IO gui MACHTELD_WRAP_GUI_INTERACTIVE} {
        ::gate::withLaneEnvironment [dict replace $none $option 1] "" {
            set inside [lmap n [present] {list $n $::env($n)}]
        }
        check "--$option sets only its own lane variable" [expr {$inside eq [list [list $name 1]]}] $inside
    }
    ::gate::withLaneEnvironment [dict create tls 1 pty 1 gui 1] "" {set inside [present]}
    check {all opt-ins together set all three and nothing else} \
        [expr {[lsort $inside] eq [lsort {MACHTELD_TEST_PUBLIC_TLS MACHTELD_TEST_PTY_IO MACHTELD_WRAP_GUI_INTERACTIVE}]}]
    set failed [catch {
        ::gate::withLaneEnvironment [dict create tls 1 pty 1 gui 1] "" {
            set ::env(MACHTELD_TEST_PIDFILE) "failing override"
            return -code error -errorcode {GATE TEST intended} "intended lane failure"
        }
    } message options]
    check {a failing lane scope propagates its error} \
        [expr {$failed && $message eq "intended lane failure" && [dict get $options -errorcode] eq {GATE TEST intended}}]
    check {a failing lane scope restores the caller's values} \
        [expr {[lmap name $laneNames {set ::env($name)}] eq [lmap name $laneNames {string cat "C:/gate fixture/inherited " $name}]}]
    foreach name $laneNames {
        unset ::env($name)
    }
    foreach fails {0 1} {
        catch {
            ::gate::withLaneEnvironment $none "" {
                set ::env(MACHTELD_TEST_WORKER_SOURCE) "temporary"
                set ::env(machteld_test_lowercase) "temporary"
                if {$fails} { error "intended" }
            }
        }
        check "variables first absent stay absent after the scope (failure $fails)" \
            [expr {[present] eq {} && ![info exists ::env(machteld_test_lowercase)]}]
    }
    set callerPath $::env(PATH)
    ::gate::withLaneEnvironment $none "" {set inside $::env(PATH)}
    check {a run without a compiler leaves PATH as it is} [expr {$inside eq $callerPath}]
    set compilerBin "C:/gate fixture/ucrt64/bin"
    ::gate::withLaneEnvironment $none $compilerBin {set inside $::env(PATH)}
    check {the compiler's directory comes first on PATH inside the scope only} \
        [expr {$inside eq "[file nativename $compilerBin];$callerPath" && $::env(PATH) eq $callerPath}]
    catch {::gate::withLaneEnvironment $none $compilerBin {error "intended"}}
    check {a failing compiler scope restores PATH} [expr {$::env(PATH) eq $callerPath}]
    unset ::env(PATH)
    ::gate::withLaneEnvironment $none $compilerBin {set inside $::env(PATH)}
    check {an absent PATH stays absent, the compiler alone on it inside} \
        [expr {![info exists ::env(PATH)] && $inside eq [file nativename $compilerBin]}]
} finally {
    foreach name [concat $laneNames PATH] {
        if {[dict exists $saved $name]} {
            set ::env($name) [dict get $saved $name]
        } else {
            unset -nocomplain ::env($name)
        }
    }
}

# ---- the tested executable, and the gate's own refusals ----

set present [info exists ::env(MACHTELD_WERROR)]
if {$present} { set savedWerror $::env(MACHTELD_WERROR) }
try {
    set ::env(MACHTELD_WERROR) 0
    check {the gate refuses MACHTELD_WERROR=0} \
        [expr {[catch {::gate::checkEnvironment} message] && [string match {*MACHTELD_WERROR=0*} $message]}]
    set ::env(MACHTELD_WERROR) 1
    check {MACHTELD_WERROR=1 is accepted} [expr {![catch {::gate::checkEnvironment}]}]
} finally {
    if {$present} { set ::env(MACHTELD_WERROR) $savedWerror } else { unset -nocomplain ::env(MACHTELD_WERROR) }
}

set identity [::gate::identify [info nameofexecutable]]
check {the gate identifies the signed build driver and its package API} \
    [expr {[dict get $identity api] eq [package require machteld] &&
        [dict get $identity version] eq [string trim [dict get [run -- [info nameofexecutable] --version] out]] &&
        [dict get $identity sha256] eq [hash file sha256 [info nameofexecutable]]}]

set work [file join [file normalize $::env(TEMP)] machteld-gate-test-[pid]-[binary encode hex [hash random 8]]]
file mkdir $work
try {
    set legacy [file join $work application_qualification_test.tcl]
    file copy -- [file join $root test application_qualification_test.tcl] $legacy
    writeText [file join $work application_corpus_test.tcl] {set ::selected $argv}
    set probeInterp [interp create]
    try {
        $probeInterp eval {package provide machteld 30}
        $probeInterp eval [list source $legacy]
        check {the historical profile qualification entry selects the SQLite archive case} \
            [expr {[$probeInterp eval {set ::selected}] eq {sqlite-profile archive}}]
    } finally {interp delete $probeInterp}

    set tested [file join $work tested.bin]
    writeText $tested "tested bytes"
    rename ::gate::readVersion ::gate::realReadVersion
    proc ::gate::readVersion {runtime args} {
        if {![llength $args]} {return $::fixtureVersion}
        if {$args ne {--api} || $::fixtureApi eq "unavailable"} {
            error "unexpected API query for $::fixtureVersion"
        }
        return $::fixtureApi
    }
    try {
        foreach {fixtureVersion fixtureApi expectedApi} {
            0.21 unavailable 0.21
            30 unavailable 30
            0.50-dev 30 30
            0.50 30 30
            0.51 30 30
        } {
            set reported [::gate::identify $tested]
            check "gate identifies $fixtureVersion with API $expectedApi" \
                [expr {[dict get $reported api] eq $expectedApi && [dict get $reported version] eq $fixtureVersion}]
        }
        foreach fixtureApi {unavailable 0.50-dev bogus} {
            check "modern gate refuses a missing or invalid --api answer ($fixtureApi)" [catch {::gate::identify $tested}]
        }
    } finally {
        rename ::gate::readVersion {}
        rename ::gate::realReadVersion ::gate::readVersion
    }
    set testedIdentity [dict create version fixture sha256 [hash file sha256 $tested]]
    set exits [file join $work exits.tcl]
    writeText $exits "package require machteld\nexit \[lindex \$argv 0\]\n"
    set changes [file join $work changes.tcl]
    writeText $changes "package require machteld\nset c \[open \[lindex \$argv 0\] ab\]\nputs -nonewline \$c x\nclose \$c\n"
    set driver [info nameofexecutable]
    check {a step that exits 0 passes} \
        [expr {![catch {::gate::execute [dict create label "gate_test step exiting 0" argv [list $driver $exits 0]] $tested $testedIdentity}]}]
    check {a step that exits otherwise fails the gate} \
        [expr {[catch {::gate::execute [dict create label "gate_test step exiting 3" argv [list $driver $exits 3]] $tested $testedIdentity} message options] &&
            [dict get $options -errorcode] eq {GATE fail} && [string match {*step exiting 3 failed*} $message]}]
    check {a step's expected exit code is accepted} \
        [expr {![catch {::gate::execute [dict create label "gate_test step expecting 3" argv [list $driver $exits 3] expect 3] $tested $testedIdentity}]}]
    check {a step that changes the tested executable fails the gate, named} \
        [expr {[catch {::gate::execute [dict create label "gate_test step changing the tested file" argv [list $driver $changes $tested]] $tested $testedIdentity} message] &&
            [string match {*the tested executable changed during gate_test step changing the tested file*} $message]}]
    check {a step that cannot start fails the gate} \
        [expr {[catch {::gate::execute [dict create label "gate_test step that cannot start" argv [list [file join $work absent.exe]]] $tested {}} message options] &&
            [dict get $options -errorcode] eq {GATE fail}}] $message
    set sleeps [file join $work sleeps.tcl]
    writeText $sleeps "package require machteld\nafter 60000\nexit 0\n"
    set started [clock milliseconds]
    set failed [catch {::gate::execute [dict create label "gate_test step past its deadline" \
        argv [list $driver $sleeps] timeout 1s] $tested $testedIdentity} message options]
    set took [expr {[clock milliseconds] - $started}]
    check {a step past its deadline is ended and fails the gate} \
        [expr {$failed && [dict get $options -errorcode] eq {GATE fail} &&
            [string match {*past its deadline failed (timeout,*} $message] && $took < 30000}] "$message ($took ms)"

    # Exercise main, the signed driver's child execution and its native
    # publication against a tiny checkout. Only the build recipe and lane
    # selection are fixtures; the latter launches the actual staged image.
    set ::gate::root [file join $work checkout]
    set public [file join $::gate::root out machteld.exe]
    set cache [file join $::gate::root cache]
    set msys [file join $::gate::root msys]
    writeText [file join $cache prefix bin tclsh90s.exe] ""
    writeText [file join $msys ucrt64 bin gcc.exe] ""
    writeText [file join $::gate::root tools release.tcl] {package require machteld
        set output [dict get $argv --output]
        file copy [info nameofexecutable] $output
    }
    set probe [file join $::gate::root probe.tcl]
    writeText $probe {package require machteld
        lassign $argv public expected candidate exitCode
        if {[file normalize [info nameofexecutable]] ne $candidate} {error "wrong candidate"}
        set actual [expr {[file exists $public] ? [hash file sha256 $public] : "absent"}]
        if {$actual ne $expected} {error "qualified name changed before the lane finished"}
        exit $exitCode
    }
    rename ::gate::plan ::gate::realPlan
    proc ::gate::plan {settings} {
        set ::observed [file normalize [dict get $settings runtime]]
        list [dict create label "qualification probe" argv \
            [list $::observed $::probe $::public $::expected $::observed $::exitCode]]
    }
    try {
        set options [list --cache $cache --msys $msys]
        set exitCode 7
        set expected absent
        set progressPath [file join $work "gate progress.jsonl"]
        set failed [catch {::gate::main [concat $options [list --progress-jsonl $progressPath]]} why]
        set reader [open $progressPath r]
        try {
            set records [lmap line [split [string trimright [read $reader] \n] \n] {json decode $line}]
        } finally {close $reader}
        check {failed gate reports paired suite and step events in execution order} [expr {
            [lmap r $records {dict get $r status}] eq {running running passed running failed failed} &&
            [lmap r $records {dict get $r kind}] eq {suite step step step step suite} &&
            [lmap r $records {dict get $r name}] eq {gate {release build} {release build} {qualification probe} {qualification probe} gate}}]
        foreach record $records {
            check {each progress record has a timestamp and each finish has a duration} [expr {
                [dict get $record schema] == 1 && [dict get $record at_ms] > 0 &&
                ([dict get $record event] eq "start" ? ![dict exists $record elapsed_ms] :
                 [dict get $record event] eq "finish" && [dict get $record elapsed_ms] >= 0)}]
        }
        check {an existing progress file is preserved} [expr {
            [catch {::gate::main [concat $options [list --progress-jsonl $progressPath]]} message] &&
            [string match {*cannot create progress log*} $message]}]
        check {an initial failed lane publishes nothing and removes its private candidate} [expr {
            $failed && [string match {*qualification probe failed (error, exit code 0x00000007)*} $why] &&
            ![file exists $public] && [file tail $observed] eq "machteld.exe" &&
            [file dirname [file dirname $observed]] eq [file dirname $public] &&
            ![file exists [file dirname $observed]]}] $why
        set first $observed
        writeText $public "prior qualified bytes"
        set expected [hash file sha256 $public]
        set failed [catch {::gate::main $options} why]
        check {a later failed lane preserves the previous release and uses a fresh directory} [expr {
            $failed && [string match {*qualification probe failed (error, exit code 0x00000007)*} $why] &&
            [hash file sha256 $public] eq $expected && $observed ne $first &&
            ![file exists [file dirname $observed]]}] $why
        set exitCode 0
        set held [open $public rb]
        try {
            set failed [catch {::gate::main $options} why]
            check {a qualified candidate cannot displace an exclusively held output} [expr {
                $failed && [string match {*cannot publish the qualified executable*} $why] &&
                [hash file sha256 $public] eq $expected && ![file exists [file dirname $observed]]}] $why
        } finally {close $held}
        set failed [catch {::gate::main [concat $options [list --skip-build --runtime $driver]]} why]
        check {testing an explicit executable leaves the qualified output alone} [expr {
            !$failed && $observed eq [file normalize $driver] && [hash file sha256 $public] eq $expected}] $why
        set lock [file join [file dirname $public] gate.lock]
        ::machteld::devcache::lock $lock
        try {
            set failed [catch {::gate::main $options} why]
            check {a contending release stops before it builds or changes the qualified output} [expr {
                $failed && [string match {*lock*held*} $why] && [file exists $lock] &&
                $observed eq [file normalize $driver] && [hash file sha256 $public] eq $expected}] $why
        } finally {::machteld::devcache::unlock $lock}
        set failed [catch {::gate::main $options} why]
        check {a successful final lane replaces the previous release with the exact bytes it ran} [expr {
            !$failed && [hash file sha256 $public] eq [dict get $identity sha256] &&
            ![file exists [file dirname $observed]] && ![file exists $lock]}] $why
        file delete -- $public
        set expected absent
        set failed [catch {::gate::main $options} why]
        check {a successful gate can publish its first qualified release} [expr {
            !$failed && [hash file sha256 $public] eq [dict get $identity sha256] &&
            ![file exists [file dirname $observed]]}] $why
    } finally {
        rename ::gate::plan {}
        rename ::gate::realPlan ::gate::plan
        set ::gate::root $root
    }
} finally {
    file delete -force $work
}

if {$failures} {
    puts stderr "$failures of $checks gate checks failed"
    exit 1
}
puts "ALL $checks GATE CHECKS PASSED"
