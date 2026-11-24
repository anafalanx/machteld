package require machteld

set testDir [file dirname [file normalize [info script]]]
if {$argv eq {--source-package}} {
    set auto_path [linsert $auto_path 0 [file join $testDir .. packages machteld-job]]
} elseif {[llength $argv]} {
    error "usage: job_test.tcl ?--source-package?"
}
package require machteld::job 1.0

namespace eval ::job_test {
    variable worker [file join $::testDir fixtures job_worker.tcl]
    variable checks 0
    variable s

    proc check {name condition} {
        variable checks
        if {!$condition} { error "FAIL job: $name" }
        incr checks
        puts "ok   job: $name"
    }

    proc command {mode} {
        variable worker
        return [list [info nameofexecutable] $worker $mode]
    }

    proc reset {} {
        variable s
        array unset s
        array set s {rows {} ends {} maxBatch 0 switched 0 sawTimer 0
            sawIdle 0 timer {} idle {} expired 0}
    }

    proc mark {kind} {
        variable s
        set s($kind) {}
        # Require the event to run strictly between actual data deliveries.
        set n [llength $s(rows)]
        set s(saw[string totitle $kind]) [expr {$n > 0 && $n < 3000}]
    }

    proc observe {mode job event data} {
        variable s
        switch -- $event {
            lines {
                if {$mode eq "restart" && !$s(switched)} {
                    set s(switched) 1
                    set s(cancelled) [$job cancel]
                    set s(restarted) [$job start [command replacement]]
                    return
                }
                if {$mode eq "burst" && ![llength $s(rows)]} {
                    set s(timer) [after 0 [list [namespace current]::mark timer]]
                    set s(idle) [after idle [list [namespace current]::mark idle]]
                }
                set s(maxBatch) [expr {max($s(maxBatch), [llength $data])}]
                lappend s(rows) {*}$data
            }
            finished { lappend s(ends) [dict get $data phase] }
        }
    }

    proc waitFor {count} {
        variable s
        set timeout [after 15000 [list [namespace current]::timeout]]
        try {
            while {[llength $s(ends)] < $count} {
                if {$s(expired)} { error "timed out waiting for terminal job callback" }
                vwait [namespace current]::s(ends)
            }
        } finally { after cancel $timeout }
    }

    proc timeout {} {
        variable s
        set s(expired) 1
        # Wake a waiting vwait without manufacturing a terminal event.
        set s(ends) $s(ends)
    }

    proc run {} {
        variable s
        variable checks
        set timers [lsort [after info]]
        set channels [lsort [chan names]]
        set children [lsort [::machteld::child list]]
        foreach mode {burst restart partial invalid failed} {
            reset
            set job [::machteld::job::Job new [list [namespace current]::observe $mode]]
            try {
                set kind [expr {$mode eq "restart" ? "interrupted" : $mode}]
                check "$mode starts" [$job start [command $kind]]
                if {$mode eq "restart"} {
                    check "second start refused while busy" [expr {![$job start [command replacement]]}]
                }
                waitFor [expr {$mode eq "restart" ? 2 : 1}]
                set snapshot [$job snapshot]
                switch -- $mode {
                    burst {
                        set expected {}
                        for {set i 0} {$i < 3000} {incr i} { lappend expected "entry $i 雪" }
                        check "all UTF-8 lines delivered once and in order" [expr {$s(rows) eq $expected}]
                        check "callback record quota" [expr {$s(maxBatch) <= 32}]
                        check "timer and idle ran while data arrived" [expr {$s(sawTimer) && $s(sawIdle)}]
                        check "one successful terminal event" [expr {
                            $s(ends) eq {done} && [dict get $snapshot phase] eq "done"}]
                    }
                    restart {
                        check "cancel and restart accepted from inside data delivery" [expr {
                            $s(cancelled) && $s(restarted)}]
                        check "retired stream stays retired" [expr {
                            $s(rows) eq {replacement} && $s(ends) eq {canceled done}
                            && [dict get $snapshot phase] eq "done"}]
                    }
                    default {
                        check "$mode fails exactly once with a diagnostic" [expr {
                            $s(ends) eq {error} && [dict get $snapshot phase] eq "error" &&
                            [dict get $snapshot error] ne {}}]
                        if {$mode eq "failed"} {
                            check "stderr survives failure" [string match {*worker diagnostic*} [dict get $snapshot log]]
                        } else {
                            check "$mode rejected before line delivery" [expr {![llength $s(rows)]}]
                        }
                    }
                }
            } finally {
                foreach name {timer idle} { if {$s($name) ne {}} { after cancel $s($name) } }
                $job destroy
            }
            check "$mode releases children, channels and timers" [expr {
                [lsort [::machteld::child list]] eq $children &&
                [lsort [chan names]] eq $channels && [lsort [after info]] eq $timers}]
        }
        puts "$checks job checks passed"
    }
}

::job_test::run
