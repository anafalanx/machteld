# Headless real-channel fairness regression; also sourced by protocol_test.tcl.
package require machteld

namespace eval ::protocol_fairness {
    variable state
    proc tick {} {
        variable state
        if {![catch {pool info $state(pool)} info] && ![dict get $info done]} {
            incr state(ticks)
            if {[string first flood-turn= [dict get $info stderr]] >= 0} {
                set state(stderrDuringFlood) 1
            }
            set state(timer) [after 1 ::protocol_fairness::tick]
        }
    }
    proc idle {} {
        variable state
        if {![catch {pool info $state(pool)} info] && ![dict get $info done]} {
            incr state(idles)
            if {$state(turns) > $state(lastIdleOut)} { incr state(idleOutProgress) }
            if {$state(errTurns) > $state(lastIdleErr)} { incr state(idleErrProgress) }
            set state(lastIdleOut) $state(turns)
            set state(lastIdleErr) $state(errTurns)
            set state(idleTimer) [after idle ::protocol_fairness::idle]
        }
    }
    proc observed {tok child kind} {
        variable state
        if {$tok ne $state(pool)} { return }
        if {$kind eq "stdout"} { incr state(turns) } else { incr state(errTurns) }
        if {!$state(started) && [dict exists $::machteld::POOL $tok readers $child] &&
                ([string length [dict get $::machteld::POOL $tok readers $child]] > 0 ||
                 [string length [dict get $::machteld::POOL $tok errbuf]] > 0)} {
            # This is AFTER real stdout bytes were consumed, not before launch
            # or while waiting for the peer to start. Count only before reply.
            set state(started) 1
            set state(timer) [after 1 ::protocol_fairness::tick]
            set state(idleTimer) [after idle ::protocol_fairness::idle]
        }
    }
    proc check {name condition} {
        if {!$condition} { error "FAIL protocol fairness: $name" }
        puts "ok   protocol fairness: $name"
    }
    proc run {peer mode {width 1}} {
        variable state
        namespace path ::machteld
        set initialTimers [lsort [after info]]
        set initialChildren [child list]
        array set state {started 0 ticks 0 idles 0 turns 0 errTurns 0 stderrDuringFlood 0 timer {} idleTimer {}
            lastIdleOut 0 lastIdleErr 0 idleOutProgress 0 idleErrProgress 0}
        set state(pool) [pool create -width $width -- [info nameofexecutable] $peer $mode]
        rename ::machteld::PoolReadable ::machteld::FairnessOriginalReadable
        proc ::machteld::PoolReadable {tok child} {
            ::machteld::FairnessOriginalReadable $tok $child
            ::protocol_fairness::observed $tok $child stdout
        }
        rename ::machteld::PoolStderr ::machteld::FairnessOriginalStderr
        proc ::machteld::PoolStderr {tok child} {
            ::machteld::FairnessOriginalStderr $tok $child
            ::protocol_fairness::observed $tok $child stderr
        }
        try {
            pool submit $state(pool) [lrepeat $width {op ignored}]
            set replies [pool wait $state(pool) -timeout 45s]
            check "$width real peer(s) completed" [expr {
                [lmap reply $replies {dict get $reply result}] eq [lrepeat $width alive]}]
            check "observation started after bytes arrived" $state(started)
            check "$mode required multiple bounded callbacks" [expr {
                ($mode eq "sustained-flood" && $state(turns) > 64) ||
                ($mode eq "sustained-stderr" && $state(errTurns) > 64) ||
                ($mode eq "mixed-flood" && $state(turns) > 64 && $state(errTurns) > 64)}]
            check "repeated timers progressed before the reply" [expr {$state(ticks) >= 2}]
            check "stderr channel progressed during stdout flood" $state(stderrDuringFlood)
            check "$mode idle work interleaves with actual stream progress" [expr {
                ($mode eq "sustained-flood" && $state(idleOutProgress) >= 2) ||
                ($mode eq "sustained-stderr" && $state(idleErrProgress) >= 2) ||
                ($mode eq "mixed-flood" && $state(idleOutProgress) >= 2 && $state(idleErrProgress) >= 2)}]
            puts "protocol fairness $mode: $state(turns) stdout turns, $state(errTurns) stderr turns, $state(ticks) timers, $state(idles) idles before reply"
        } finally {
            foreach key {timer idleTimer} {
                if {$state($key) ne {}} { after cancel $state($key) }
            }
            rename ::machteld::PoolReadable {}
            rename ::machteld::FairnessOriginalReadable ::machteld::PoolReadable
            rename ::machteld::PoolStderr {}
            rename ::machteld::FairnessOriginalStderr ::machteld::PoolStderr
            pool close $state(pool)
        }
        check "all probe children and timers released" [expr {
            [lsort [after info]] eq $initialTimers && [child list] eq $initialChildren}]
    }
}
foreach mode {sustained-flood sustained-stderr} {
    ::protocol_fairness::run [file join [file dirname [file normalize [info script]]] fixtures protocol_program.tcl] $mode
}
::protocol_fairness::run [file join [file dirname [file normalize [info script]]] fixtures protocol_program.tcl] mixed-flood 4
