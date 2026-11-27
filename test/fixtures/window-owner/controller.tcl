# Every UI entry installs the recording toolkit before calling any X
# function. The native worker entry is dispatched before this script.
source -encoding utf-8 [file join [file dirname [info script]] recording_tk.tcl]
lassign $argv mode work helper
set ::notes {}
proc ::note {text} {lappend ::notes $text; return {}}
proc ::unexpectedChunk {bytes} {lappend ::notes [list unexpected $bytes]; return {ok {}}}
proc ::savedTask {name task} {set ::tasks($name) $task; return {}}
proc ::rememberStream {ticket} {set ::parentStream $ticket; return {}}
proc ::cancelOnClose {} {
    ::application::streams::cancel $::parentStream
    note observer
}
proc ::observe {window} {
    set rt ::machteld::compiledApplication::@rt
    if {[llength [info commands ${rt}::workerOnClose]]} {
        set owner [${rt}::workerControl window [${rt}::tkPath tk_window $window]]
        ${rt}::workerOnClose $owner ::cancelOnClose
    } else {
        ${rt}::tkOnClose $window ::cancelOnClose
    }
    return {}
}
proc ::assert {condition message} {if {![uplevel 1 [list expr $condition]]} {error "$message; events=$::notes"}}
proc ::until {condition} {
    set deadline [expr {[clock milliseconds] + 12000}]
    while {![uplevel 1 [list expr $condition]]} {
        if {[clock milliseconds] >= $deadline} {error "timed out waiting for $condition; events=$::notes"}
        after 15 {incr ::poll}
        vwait ::poll
    }
}
proc ::release {name} {close [open [file join $::work $name.release] {WRONLY CREAT EXCL}]}
proc ::readAppTask {} {set ::appReply [::application::ui::finish $::tasks(app)]}
proc ::fixtureFault {value} {
    return -code error -errorcode {TEST WORKER_REPLY} -fixturevalue $value {cannot apply lookup}
}
proc ::faultPane {report} {
    lappend ::reports $report
    set ::rolledBack [expr {[::journal onecolumn {SELECT count(*) FROM journal}] == 0}]
}
proc ::faultClicks {writer} {
    dict for {path state} $::recordTk::widgets {
        switch [dict get $state kind] {
            button {set buttons([$path cget -text]) $path}
            label {set label $path}
            window {if {[dict get $state title] eq "Reader"} {set reader $path}}
        }
    }
    after 0 [list $buttons(Submit) invoke]
    until {[file exists [file join $::work local.started]]}
    after 0 [list $buttons(Refresh) invoke]
    until {[$label cget -text] eq "ready"}
    $label configure -text pending
    release local
    until {[llength $::reports]}
    set report [lindex $::reports 0]
    assert {[dict get $report operation] eq "worker-resume"} {resumed operation missing}
    assert {[dict get $report message] eq "cannot apply lookup"} {original error message missing}
    set options [dict get $report options]
    assert {[dict get $options -fixturevalue] eq "local" && [dict get $options -errorcode] eq {TEST WORKER_REPLY}} {original error options missing}
    set site [dict get $options -appcompilerlocation]
    assert {[dict get $site module] eq "faults" && [dict get $site line] == 2 && [dict get $site column] == 41} {original extern target location missing}
    assert {[string match {*typed source faults:2:41*} [dict get $options -errorinfo]]} {original stack trace missing}
    assert {$::rolledBack} {journal entry visible when sink ran}
    assert {[::application::@events::last_fault] eq $report} {diagnostic cannot be recovered}
    assert {[winfo exists $writer] && [winfo exists $reader]} {the event closed an unrelated window}
    after 0 [list $buttons(Refresh) invoke]
    until {[$label cget -text] eq "ready"}
    assert {[llength $::reports] == 1 && $::notes eq {} && $::backgroundFaults eq {}} {duplicate or modal fault delivery}
    assert {[::machteld::child list] eq {}} {finished worker was retained}
    destroy $writer
}
if {$mode eq "faults"} {
    package require sqlite3
    set file [file join $work fault.db]
    sqlite3 ::journal $file
    set ::reports {}
    set ::backgroundFaults {}
    interp bgerror {} [list lappend ::backgroundFaults]
    ::application::@events::on_fault ::faultPane
    set ::recordTk::waiting ::faultClicks
    try {
        ::journal eval {CREATE TABLE journal (n INTEGER)}
        assert {[::application::faults::open $file] eq {ok {}}} {faulted event escaped the main loop}
        assert {![dict size $::recordTk::widgets]} {scoped windows were retained}
        assert {[interp bgerror {}] eq {lappend ::backgroundFaults}} {application modified interpreter background policy}
    } finally {::journal close}
    puts ok
    return
}
proc ::click {window} {
    dict for {path state} $::recordTk::widgets {set widget([dict get $state kind]) $path}
    set button $widget(button)
    set oldClick [$button cget -command]
    after 0 {set ::heartbeat 1}
    $button invoke
    assert {![info exists ::heartbeat]} {callback drove a nested event loop}
    until {[info exists ::heartbeat]}
    if {$::mode eq "resume"} {
        until {[file exists [file join $::work local.started]]}
        assert {[$widget(label) cget -text] eq "pending"} {label changed before worker release}
        release local
        until {"updated" in $::notes}
        assert {[$widget(label) cget -text] eq "local"} {live worker reply failed to update label}
        destroy $window
    } elseif {$::mode eq "streams"} {
        until {"nested" in $::notes}
        assert {[llength [::machteld::child list]] == 2} {expected both stream processes}
        destroy $window
    } else {
        until {[file exists [file join $::work app.started]]}
        if {$::mode eq "close"} {
            until {[file exists [file join $::work local.started]] && "nested" in $::notes}
            assert {[llength [::machteld::child list]] == 4} {expected local worker, app worker and two streams}
        }
        destroy $window
        assert {[llength [::machteld::child list]] == 1} {closing must keep only the application worker}
        ::application::workers handle application ::readAppTask
        release app
        until {[info exists ::appReply]}
        assert {$::appReply eq {ok app}} {surviving application worker lost its reply}
    }
    if {$::mode in {streams close}} {assert {"observer" in $::notes} {owner did not dispatch close observers}}
    set before $::notes
    uplevel #0 $oldClick
    after 30 {set ::drained 1}
    until {[info exists ::drained]}
    assert {$before eq $::notes} {late button, worker, or stream callback ran}
    assert {"terminal" ni $::notes && [lsearch -index 0 $::notes unexpected] == -1} {closed stream delivered a callback}
    if {$::mode ne "resume"} {assert {"updated" ni $::notes && "worker error" ni $::notes} {closed window received a worker reply}}
    assert {[llength [::machteld::child list]] == 0} {owned child handles remained}
}
set ::recordTk::waiting ::click
set outcome [::application::ui::show $mode $helper]
assert {$outcome eq {ok {}}} "window failed: $outcome"
puts ok
