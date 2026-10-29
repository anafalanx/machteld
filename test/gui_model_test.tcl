package require machteld

set HERE [file dirname [file normalize [info script]]]
set EXAMPLE [file join $HERE .. examples project-inspector]
source [file join $EXAMPLE model.tcl]
set TEMP_ROOT [file normalize $env(TEMP)]
set WORK_ROOT [file normalize [file join $TEMP_ROOT machteld-inspector-[pid]-[clock clicks]]]
if {[file dirname $WORK_ROOT] ne $TEMP_ROOT || [file exists $WORK_ROOT]} { error "unsafe test workspace" }
set WORK [file join $WORK_ROOT {space 雪}]
file mkdir $WORK
set ch [open [file join $WORK {café 雪.txt}] w]
puts $ch {read-only fixture}; close $ch
set originalDigest [hash file sha256 [file join $WORK {café 雪.txt}]]
set fails 0; set checks 0; set ticks 0; set bgerrors {}
proc bgerror {message} { lappend ::bgerrors $message }
proc check {name condition} {
    incr ::checks
    if {$condition} { puts "ok   $name" } else { incr ::fails; puts "FAIL $name" }
}
proc tick {} { incr ::ticks; set ::tickTimer [after 5 tick] }
proc inspect_wait {job {limit 12000}} {
    set until [expr {[clock milliseconds]+$limit}]
    while {[dict get [$job snapshot] phase] eq "running" && [clock milliseconds] < $until} {
        set ::woke 0; set timer [after 5 {set ::woke 1}]
        vwait ::woke; after cancel $timer
    }
    if {[dict get [$job snapshot] phase] eq "running"} { error "test job did not finish" }
    return [$job snapshot]
}
set baseline [child list]
set job [::inspector::Job new [file join $EXAMPLE inspect.tcl]]
tick
try {
    check "first start accepted" [$job start $WORK]
    check "duplicate start rejected" [expr {![$job start $WORK]}]
    set state [inspect_wait $job]
    check "normal inspection completes" [expr {[dict get $state phase] eq "done"}]
    check "Unicode and space path retained" [expr {
        [dict get [lindex [dict get $state rows] 0] path] eq [file join $WORK {café 雪.txt}]}]
    check "file metadata preserved" [expr {[dict get [lindex [dict get $state rows] 0] size] > 0}]
    check "normal child released" [expr {[child list] eq $baseline}]
    $job start [file join $WORK absent]
    set state [inspect_wait $job]
    check "missing directory is a recoverable error" [expr {[dict get $state phase] eq "error" &&
        [string match {*Not a directory*} [dict get $state error]]}]
    $job start $WORK fail
    set state [inspect_wait $job]
    check "deliberate failure is actionable" [expr {[dict get $state phase] eq "error" &&
        [string match {*Deliberate demonstration failure*} [dict get $state error]]}]
    $job start $WORK
    check "failure can be followed by successful job" [expr {[dict get [inspect_wait $job] phase] eq "done"}]
    set before $ticks
    $job start $WORK noisy
    set state [inspect_wait $job]
    check "output burst completes without deadlock" [expr {[dict get $state phase] eq "done"}]
    check "event loop progresses under output" [expr {$ticks-$before > 5}]
    check "diagnostic retention bounded" [expr {[string length [dict get $state log]] == 8192}]
    check "latest diagnostics retained" [string match {*Output demonstration 1199*} [dict get $state log]]
    $job start $WORK slow
    set timer [after 100 [list $job cancel]]
    set state [inspect_wait $job]; after cancel $timer
    check "cancel settles immediately" [expr {[dict get $state phase] eq "canceled"}]
    check "repeat cancel is harmless" [expr {![$job cancel]}]
    check "cancel releases owned child" [expr {[child list] eq $baseline}]
    # An old queued callback cannot touch the new generation's streams.
    $job start $WORK
    $job readable -1 stdout
    $job poll -1
    check "stale callbacks cannot disrupt recovery" [expr {[dict get [inspect_wait $job] phase] eq "done"}]
    $job start $WORK slow
    $job close
    check "close stops active work" [expr {[dict get [$job snapshot] phase] eq "closed" && [child list] eq $baseline}]
    check "closed model cannot restart" [expr {![$job start $WORK]}]
    $job destroy
    set job {}

    # Reentrant action from an observer is an intentional lifecycle test.
    proc stop_on_start {object snapshot} {
        if {[dict get $snapshot phase] eq "running"} { $object cancel }
    }
    set job [::inspector::Job new [file join $EXAMPLE inspect.tcl] stop_on_start]
    $job start $WORK slow
    check "observer may cancel reentrantly" [expr {[dict get [$job snapshot] phase] eq "canceled" && [child list] eq $baseline}]
    $job destroy
    proc broken_view {object snapshot} { error "deliberate view failure" }
    set job [::inspector::Job new [file join $EXAMPLE inspect.tcl] broken_view]
    $job start $WORK slow
    check "observer exception stops and releases work" [expr {
        [dict get [$job snapshot] phase] eq "error" && [child list] eq $baseline}]
    check "observer exception remains observable" [expr {[dict get [$job snapshot] error] eq "deliberate view failure"}]
    $job destroy
    proc close_then_fail {object snapshot} { $object close; error "closed observer failed" }
    set job [::inspector::Job new [file join $EXAMPLE inspect.tcl] close_then_fail]
    $job start $WORK slow
    check "observer failure cannot reopen a closed controller" [expr {
        [dict get [$job snapshot] phase] eq "closed" && ![$job start $WORK]}]
    $job destroy
    proc destroy_on_log {object snapshot} {
        if {[dict get $snapshot log] ne {}} { $object destroy }
    }
    set job [::inspector::Job new [file join $EXAMPLE inspect.tcl] destroy_on_log]
    $job start $WORK noisy
    set deadline [expr {[clock milliseconds]+3000}]
    while {[info object isa object $job] && [clock milliseconds] < $deadline} {
        set timer [after 5 {set ::woke 1}]
        vwait ::woke; after cancel $timer
    }
    check "observer can destroy controller during stream notification" [expr {
        ![info object isa object $job] && [child list] eq $baseline}]
    if {[info object isa object $job]} { $job destroy }
    set job {}
    check "observer destruction causes no background callback error" [expr {$bgerrors eq {}}]
    set job [::inspector::Job new [file join $HERE fixtures inspector_protocol.tcl]]
    foreach kind {oversize partial duplicate invalidutf8 incomplete aftercomplete rows} {
        $job start $kind
        set state [inspect_wait $job]
        check "bad protocol is contained: $kind" [expr {[dict get $state phase] eq "error" && [child list] eq $baseline}]
        check "bad protocol has bounded retained data: $kind" [expr {
            [llength [dict get $state rows]] <= 500 && [string length [dict get $state log]] <= 8192}]
    }
    check "inspection modes did not modify fixture" [expr {
        [hash file sha256 [file join $WORK {café 雪.txt}]] eq $originalDigest &&
        [llength [glob -directory $WORK *]] == 1}]
    $job destroy; set job {}
    after cancel $tickTimer
    source [file join $HERE gui_model_fairness_test.tcl]
    incr checks $::inspector_fairness::checks
    check "no background callback errors" [expr {$bgerrors eq {}}]
} finally {
    after cancel $tickTimer
    if {$job ne {}} { $job destroy }
    if {[file dirname [file normalize $WORK_ROOT]] ne $TEMP_ROOT} { error "refusing escaped test cleanup" }
    file delete -force $WORK_ROOT
}
puts "$checks GUI-model checks, $fails failures"
exit [expr {$fails != 0}]
