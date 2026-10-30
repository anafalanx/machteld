package require machteld 0.21

# test/gate_test.tcl -- the gate's own choices, checked without running a lane:
# how --group selections expand and which options each needs; which steps each
# group plans (fixtures only where they are used, the opt-in lanes only behind
# their options, a shared step once); the lanes' environment (inherited opt-ins
# and overlays removed, only the requested ones set, the caller's environment
# back after success and after failure); and the tested executable's identity
# held through every step.
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
check {no --group runs every group after the release build} \
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
foreach option {--public-tls --interactive-pty} {
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
# The build publishes the runtime it tests, so a file named with --runtime is
# tested only as it is; a signed copy must never be built over.
set signed C:/release/signed/machteld.exe
check {the build goes to out/machteld.exe} \
    [expr {[dict get $default runtime] eq [file join $root out machteld.exe]}]
check {--runtime is refused when the gate would build over it} \
    [expr {[refused [list --runtime $signed] {*--runtime*would publish over it*--skip-build*}] &&
        [refused [list --group release --runtime $signed] {*--runtime*would publish over it*}] &&
        [refused [list --runtime $signed --interactive-gui] {*--runtime*would publish over it*}]}]
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
check {--interactive-gui alone needs the runtime} [::gate::needs [settings {--group reference-generator --interactive-gui}] runtime]

check {the fast group compiles nothing} [expr {[compiled [::gate::plan $fast]] eq {}}]
check {the integration group compiles its own fixtures and the process fixture} \
    [expr {[compiled [::gate::plan [settings {--group integration}]]] eq [list \
        {fixture process_fixture.c} {fixture http_fixture.c} {SQLite test object} \
        {fixture sqlite_lock_fixture.c} {fixture cmdline_test.c}]}]
check {the packaging group compiles only the process fixture} \
    [expr {[compiled [::gate::plan [settings {--group packaging}]]] eq {{fixture process_fixture.c}}}]
set nvPlan [::gate::plan [settings {--group native-validation}]]
check {the native-validation group compiles the process fixture, the telemetry probe and the trapped drivers} \
    [expr {[lrange [compiled $nvPlan] 0 2] eq {{fixture process_fixture.c} {fixture native_probe.c} {UB-trap canary}} &&
        [llength [lsearch -all [compiled $nvPlan] {trapped *: compile}]] == 7}]
check {the reference-generator group compiles nothing} \
    [expr {[compiled [::gate::plan $generator]] eq {}}]

set releasePlan [::gate::plan [settings {}]]
set releaseLabels [labels $releasePlan]
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
    C:/fake-msys/ucrt64/bin/gcc.exe [file join $root out test] [file join $root out machteld.exe]]
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
check {the trapped drivers run the command line, allocation failures, Unicode, JSON, native, hash and identity boundaries} \
    [expr {$driven eq [list cmdline-trap.exe cmdline-allocation-trap.exe wintext-trap.exe \
        {json-trap.exe json_test.tcl} {json-trap.exe native_adversarial_test.tcl} \
        native-boundary-trap.exe hash-boundary-trap.exe {identity-trap.exe identity_native_test.tcl}]}] $driven
set identityRun [lindex $nvPlan [lsearch -exact $nvLabels {trapped identity}]]
check {the trapped identity driver gets both basekits and a work folder, all deleted after it} \
    [expr {[dict keys [dict get $identityRun extract]] eq {basekit/console.exe basekit/gui.exe} &&
        [dict get $identityRun cleanup] eq [lrange [dict get $identityRun argv] 2 4]}]
set guiPlan [::gate::plan [settings {--interactive-gui}]]
check {the window-opening GUI lane runs only behind --interactive-gui, last} \
    [expr {"gui_widget_test.tcl" ni [scripts $releasePlan] &&
        [file tail [lindex [dict get [lindex $guiPlan end] argv] 1]] eq "gui_widget_test.tcl"}]
set entry [lindex $releasePlan [lsearch -exact $releaseLabels entry]]
set bareHost [lindex [dict get $entry argv] end]
check {the entry test gets the process fixture and a bare host of its own, deleted after it} \
    [expr {[dict get $entry extract] eq [list basekit/console.exe $bareHost] &&
        [dict get $entry cleanup] eq [list $bareHost] &&
        [string match .machteld-entry-basekit-*.exe [file tail $bareHost]]}]
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
set everything [concat $releasePlan [::gate::plan [settings {--interactive-gui}]]]
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
    protocol_fairness_test.tcl test/protocol_test.tcl identity_native_test.tcl test/app_identity_test.tcl \
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
check {the gate names a runtime by its --version and SHA-256} \
    [expr {[dict get $identity version] eq [package require machteld] &&
        [dict get $identity sha256] eq [hash file sha256 [info nameofexecutable]]}]

set work [file join [file normalize $::env(TEMP)] machteld-gate-test-[pid]-[binary encode hex [hash random 8]]]
file mkdir $work
try {
    set tested [file join $work tested.bin]
    writeText $tested "tested bytes"
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
} finally {
    file delete -force $work
}

if {$failures} {
    puts stderr "$failures of $checks gate checks failed"
    exit 1
}
puts "ALL $checks GATE CHECKS PASSED"
