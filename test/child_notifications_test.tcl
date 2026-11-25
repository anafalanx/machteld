package require machteld

namespace eval ::childNotifications {
    namespace path ::machteld
    variable fixture [file normalize [lindex $::argv 0]]
    variable results {}
    variable serial 0
    variable tokens {}
    proc check {label condition} {
        if {!$condition} {error "FAIL child notifications: $label"}
        puts "ok   $label"
    }
    proc receive {token result} {
        variable results
        dict lappend results $token $result
        incr [namespace current]::serial
    }
    proc await {token} {
        variable results
        variable serial
        set timer [after 15000 [list set [namespace current]::serial expired]]
        try {
            while {![dict exists $results $token]} {
                if {$serial eq "expired"} {error "no completion for $token"}
                vwait [namespace current]::serial
            }
        } finally {after cancel $timer}
        return [lindex [dict get $results $token] 0]
    }
    proc start {args} {
        variable tokens
        set token [child start -onexit [namespace current]::receive {*}$args]
        lappend tokens $token
        return $token
    }
    proc retire {slave token result} {
        interp delete $slave
        set ::childNotifications::retired [dict get $result status]
    }
    proc background {message options} {
        set ::childNotifications::backgroundError [list $message [dict get $options -errorcode]]
    }

    try {
        foreach prefix [list {} "\{"] {
            check "malformed or empty prefix fails before launch" [expr {
                [catch {child start -onexit $prefix -- $fixture ok} msg opts] &&
                [dict get $opts -errorcode] eq {MACHTELD CHILD badvalue}}]
        }
        set waiting [start -- $fixture fail payload]
        set expected [child wait $waiting]
        check "blocking wait and queued callback agree on captured output, status and exit" [expr {
            [await $waiting] eq $expected && [dict get $expected exit] == 7}]
        for {set i 0} {$i < 20} {incr i} {lappend quick [start -- $fixture ok $i]}
        foreach t $quick {await $t}
        update
        set counts [lmap t $quick {llength [dict get $results $t]}]
        check "twenty immediate exits are each delivered exactly once" [expr {$counts eq [lrepeat 20 1]}]
        set scratch [file tempdir]
        try {
            set tree [start -- $fixture descendant-parent 150 [file join $scratch pid]]
            set result [await $tree]
            check "completion waits for descendants and drains their last output" [expr {
                [dict get $result out] eq "PARENT-OUT\nDESCENDANT-OUT\n" &&
                [dict get $result err] eq "PARENT-ERR\nDESCENDANT-ERR\n"}]
        } finally {file delete -force $scratch}
        set closed [start -- $fixture ok retired]
        child wait $closed
        child close $closed
        update
        check "close cancels an already queued completion" [expr {![dict exists $results $closed]}]
        set slow [start -timeout 70ms -- $fixture hang 5000]
        check "an autonomously enforced deadline reaches the event loop" [expr {
            [dict get [await $slow] status] eq "timeout"}]
        set channelChild [start -channels -- $fixture stdin-echo]
        set io [child info $channelChild]
        puts -nonewline [dict get $io stdin] {safe input}
        set requested [child shutdown $channelChild]
        check "shutdown closes stdin once and leaves stdout readable" [expr {
            [dict get $requested stdin] && [child shutdown $channelChild] eq $requested &&
            [dict get [await $channelChild] status] eq "ok" &&
            [read [dict get $io stdout]] eq "safe input"}]
        set ignores [start -- $fixture hang 5000]
        check "shutdown reports a worker with no cooperative endpoint" [expr {
            [child shutdown $ignores] eq {windows 0 stdin 0} && [dict get [child info $ignores] running]}]
        child kill $ignores
        check "explicit escalation reports whole-job termination" [expr {[dict get [await $ignores] status] eq "killed"}]
        set slave [interp create]
        try {
            interp eval $slave {load {} machteldproc}
            interp alias $slave notify {} [namespace current]::receive
            set count $serial
            set t [interp eval $slave [list ::machteld::child start -onexit notify -- $fixture ok retired]]
            interp eval $slave [list ::machteld::child wait $t]
        } finally {interp delete $slave}
        update
        check "deleting an interpreter discards its queued completion" [expr {$serial == $count}]

        set slave [interp create]
        try {
            interp eval $slave {load {} machteldproc}
            interp alias $slave retire {} [namespace current]::retire $slave
            interp alias $slave background {} [namespace current]::background
            interp bgerror $slave background
            interp eval $slave {proc failCallback {args} {return -code error -errorcode {TEST CALLBACK} deliberate}}
            set t [interp eval $slave [list ::machteld::child start -onexit failCallback -- $fixture ok ok]]
            set guard [after 10000 [list set [namespace current]::backgroundError expired]]
            try {vwait [namespace current]::backgroundError} finally {after cancel $guard}
            check "a callback error reaches the interpreter background handler" [expr {
                $backgroundError eq {deliberate {TEST CALLBACK}} &&
                [dict get [interp eval $slave [list ::machteld::child wait $t]] status] eq "ok"}]
            interp eval $slave [list ::machteld::child start -onexit retire -- $fixture ok done]
            set guard [after 10000 [list set [namespace current]::retired expired]]
            try {vwait [namespace current]::retired} finally {after cancel $guard}
            check "a callback can delete its own interpreter" [expr {$retired eq "ok" && ![interp exists $slave]}]
        } finally {if {[interp exists $slave]} {interp delete $slave}}
    } finally {
        foreach t $tokens {catch {child close $t}}
    }
}
namespace delete ::childNotifications
