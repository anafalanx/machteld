package require machteld

# Bundled only in the integration test. Route every role through the
# example's normal main.tcl; drive the GUI via its public Tk controls.
namespace eval ::guiTest {
    proc record {name text} {
        set f [open [file join $::env(MACHTELD_LOOKUP_TEST_DIR) $name] a]
        try { puts $f $text } finally { close $f }
    }
    proc fail {text} { record result.txt $text; exit 1 }
    proc rootEvent {event widget} {
        if {$widget eq "."} { record $event-[pid] yes }
    }
    proc check {name condition} {
        if {!$condition} { error "failed: $name" }
    }
    proc turn {} {
        after 5 [list set [namespace current]::wake 1]
        vwait [namespace current]::wake
    }
    proc until {description condition} {
        set limit [expr {[clock milliseconds] + 15000}]
        while {![uplevel 1 [list expr $condition]]} {
            if {[clock milliseconds] >= $limit} { error "timed out: $description" }
            turn
        }
    }
    proc page {group offset} {
        set expected {}
        reference eval {
            SELECT id,category,name FROM items WHERE $group='All' OR category=$group
            ORDER BY id LIMIT 50 OFFSET $offset
        } row {
            lappend expected [list $row(id) $row(category) $row(name)]
        }
        set shown [lmap iid [.results children {}] { .results item $iid -values }]
        check "displayed $group rows at offset $offset match independent SQL" [expr {
            [llength $expected] == 50 && $shown eq $expected}]
    }
    proc onInsert {command code result operation} {
        variable scheduled
        if {!$scheduled && $code == 0 && [lindex $command 1] eq "insert"} {
            set scheduled 1
            after 0 [list [namespace current]::selectFirst]
        }
    }
    proc selectFirst {} {
        variable rowsAtSelection
        set rows [.results children {}]
        set rowsAtSelection [llength $rows]
        .results selection set [lindex $rows 0]
    }
    proc blockedSearch {group} {
        reference eval {BEGIN EXCLUSIVE}
        .filters.category set $group
        .filters.search invoke
        # The worker has opened its own database and emitted an actual
        # progress record. The lock keeps SELECT waiting until the UI acts.
        until "worker opened the locked catalogue" {
            $::lookup::phase eq "loading" && [string match {Reading catalogue*} $::lookup::status]}
        set tokens [::machteld::child list]
        check "one supervised worker" [expr {[llength $tokens] == 1}]
        return [dict get [::machteld::child info [lindex $tokens 0]] pid]
    }
    proc exited {id} {
        if {![catch {::machteld::mtps info $id} msg opts]} { return 0 }
        if {[dict get $opts -errorcode] ne {MACHTELD MTPS notfound}} { return -options $opts $msg }
        return 1
    }
    proc exercise {path} {
        package require sqlite3
        sqlite3 [namespace current]::reference $path
        try {
            until "first visible page" {$::lookup::phase eq "ready" && [winfo ismapped .results]}
            page All 0
            # A real selection event has a turn after data reaches the widget
            # and before painting the rest of the second page.
            variable scheduled 0
            variable rowsAtSelection 0
            trace add execution .results leave [namespace current]::onInsert
            try {
                .footer.next invoke
                until "second page" {$::lookup::phase eq "ready"}
            } finally { trace remove execution .results leave [namespace current]::onInsert }
            check "Tk accepted a selection during paging" [expr {
                $rowsAtSelection > 0 && $rowsAtSelection < 50 && [.results selection] eq "51"}]
            page All 50

            set retired [blockedSearch Parts]
            after 0 {.filters.cancel invoke}
            until "Cancel handled by the Tk event loop while SELECT waits" {$::lookup::phase eq "canceled"}
            check "Cancel releases ownership" [expr {![llength [::machteld::child list]]}]
            reference eval {ROLLBACK}
            .filters.category set Kits
            .filters.search invoke
            until "replacement lookup" {$::lookup::phase eq "ready"}
            until "retired worker exited" {[exited $retired]}
            page Kits 0

            set closing [blockedSearch Supplies]
            uplevel #0 [wm protocol . WM_DELETE_WINDOW]
            check "close destroyed the window" [expr {[catch {winfo exists .} exists] || !$exists}]
            check "close releases ownership" [expr {![llength [::machteld::child list]]}]
            until "worker from closed window exited" {[exited $closing]}
            reference eval {ROLLBACK}
            # Check the worker did not map a second application window.
            foreach id [list $retired $closing] {
                check "worker $id disposed of its GUI root without mapping it" [expr {
                    [file exists [file join $::env(MACHTELD_LOOKUP_TEST_DIR) dropped-$id]] &&
                    ![file exists [file join $::env(MACHTELD_LOOKUP_TEST_DIR) mapped-$id]]}]
            }
        } finally { reference close }
    }
    proc run {path} {
        if {[catch {exercise $path} message options]} { fail [dict get $options -errorinfo] }
        record result.txt PASS
        exit 0
    }
}

if {[info exists env(MACHTELD_LOOKUP_TEST_DIR)]} {
    proc bgerror {message} { ::guiTest::fail "Tk background error: $message" }
    if {[lindex $argv 0] eq "--worker"} {
        if {[winfo ismapped .]} { ::guiTest::record mapped-[pid] yes }
        bind . <Map> +[list ::guiTest::rootEvent mapped %W]
        bind . <Destroy> +[list ::guiTest::rootEvent dropped %W]
    } else {
        after 0 [list ::guiTest::run [lindex $argv 0]]
    }
}
source [file join [file dirname [info script]] main.tcl]
