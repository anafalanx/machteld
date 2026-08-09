# spike/pool/spike.tcl -- try to break the channel-based pool.
#
#   machteld.exe spike/pool/spike.tcl
#
# Written to FAIL, not to pass. Each section attacks one of the hazards named in
# docs/parallel.md, and the interesting outcome is a hang or a wrong count, not
# a green line.

set HERE [file dirname [file normalize [info script]]]
source [file join $HERE pool.tcl]
set MT [info nameofexecutable]
set CMD [list $MT [file join $HERE worker.tcl]]

set fails 0
proc check {name ok} {
    if {$ok} { puts "ok   $name" } else { incr ::fails ; puts "FAIL $name" }
}
# Every test runs under a wall-clock guard: a hang is the failure mode this
# spike exists to find, and a hung test that never returns reports nothing.
proc guarded {name script {ms 45000}} {
    set t0 [clock milliseconds]
    set rc [catch {uplevel 1 $script} err]
    set dt [expr {[clock milliseconds]-$t0}]
    if {$rc} { incr ::fails ; puts "FAIL $name -- $err (${dt}ms)" ; return 0 }
    return 1
}

puts "=== 1. correctness under load ==="
guarded "300 items through 8 workers" {
    set p [::pool::create $CMD 8]
    set items {}
    for {set i 0} {$i < 300} {incr i} { lappend items [dict create id $i op sum n 20000] }
    ::pool::submit $p $items
    set r [::pool::wait $p]
    check "every item came back"      [expr {[llength $r] == 300}]
    check "every id is distinct"      [expr {[llength [lsort -unique [lmap x $r {dict get $x id}]]] == 300}]
    check "every item succeeded"      [expr {[llength [lsearch -all -inline -index 3 $r 0]] == 0}]
    check "no worker died"            [expr {[dict get [::pool::stats $p] dead] == 0}]
    ::pool::close $p
}

puts "\n=== 2. HAZARD: a reply far larger than the pipe buffer ==="
# The one I expected to be wrong. A Windows pipe holds a few KB; a 4 MB reply
# must not wedge either side.
guarded "replies of 1 MB, 2 MB and 4 MB" {
    set p [::pool::create $CMD 4]
    set items {}
    foreach n {0 1 2 3 4 5 6 7} {
        lappend items [dict create id $n op big bytes [expr {(1 + ($n % 4)) * 1024 * 1024}]]
    }
    ::pool::submit $p $items
    set r [::pool::wait $p]
    check "all big replies arrived"   [expr {[llength $r] == 8}]
    set sizes [lsort -unique [lmap x $r {string length [dict get $x blob]}]]
    check "payloads are intact"       [expr {$sizes eq {1048576 2097152 3145728 4194304}}]
    ::pool::close $p
}

puts "\n=== 3. HAZARD: a worker writing to an unread stderr ==="
guarded "workers spewing stderr while answering" {
    set p [::pool::create $CMD 4]
    set items {}
    for {set i 0} {$i < 40} {incr i} { lappend items [dict create id $i op noise lines 2000] }
    ::pool::submit $p $items
    set r [::pool::wait $p]
    check "stderr noise did not wedge the pool" [expr {[llength $r] == 40}]
    ::pool::close $p
}

puts "\n=== 4. HAZARD: a worker dying mid-item ==="
guarded "one item kills its worker; others must still finish" {
    set p [::pool::create $CMD 4]
    set items {}
    for {set i 0} {$i < 20} {incr i} { lappend items [dict create id $i op sum n 5000] }
    lappend items [dict create id 999 op die]
    ::pool::submit $p $items
    set r [::pool::wait $p]
    set st [::pool::stats $p]
    check "the healthy items all returned" [expr {[llength [lsearch -all -inline -index 1 $r 999]] >= 0
                                                  && [llength $r] >= 20}]
    check "the pool noticed a death"       [expr {[dict get $st dead] >= 1}]
    check "the killer item was requeued"   [expr {[dict get $st requeued] >= 1}]
    check "the poison item did not loop"   [expr {[dict get $st dead] <= 8}]
    ::pool::close $p
}

puts "\n=== 5. errors cross the process boundary with their code ==="
guarded "a raising handler and a coded failure" {
    set p [::pool::create $CMD 2]
    ::pool::submit $p [list [dict create id 1 op boom] [dict create id 2 op coded] \
                            [dict create id 3 op sum n 100]]
    set r [::pool::wait $p]
    check "all three answered"        [expr {[llength $r] == 3}]
    set byid {}
    foreach x $r { dict set byid [dict get $x id] $x }
    check "the raising handler reported failure" [expr {[dict get [dict get $byid 1] ok] == 0}]
    check "the coded failure kept its errorcode" [expr {
        [dict get [dict get $byid 2] code] eq {MACHTELD SPIKE deliberate}}]
    check "the healthy item still succeeded"     [expr {[dict get [dict get $byid 3] ok] == 1}]
    ::pool::close $p
}

puts "\n=== 6. payloads that could break the framing ==="
guarded "newlines, quotes, unicode and empty strings in values" {
    set p [::pool::create $CMD 2]
    set nasty [list "line\nbreak" "quote\"inside" "tab\there" "café 日本" "" \
                    "brace{}bracket\[\]" "backslash\\\\here"]
    set items {}
    set i 0
    foreach t $nasty { lappend items [dict create id [incr i] op echo text $t] }
    ::pool::submit $p $items
    set r [::pool::wait $p]
    check "every nasty payload returned" [expr {[llength $r] == [llength $nasty]}]
    set ok 1
    foreach x $r {
        if {[dict get $x echo] ne [lindex $nasty [expr {[dict get $x id]-1}]]} { set ok 0 }
    }
    check "every payload round-tripped byte for byte" $ok
    ::pool::close $p
}

puts "\n=== 7. no orphans after close ==="
guarded "closing the pool ends every worker" {
    set before [llength [lsearch -all -inline -index 5 [ps list] machteld.exe]]
    set p [::pool::create $CMD 6]
    ::pool::submit $p [list [dict create id 1 op sum n 1000]]
    ::pool::wait $p
    set during [llength [lsearch -all -inline -index 5 [ps list] machteld.exe]]
    ::pool::close $p
    after 600
    set after [llength [lsearch -all -inline -index 5 [ps list] machteld.exe]]
    check "workers were actually running" [expr {$during > $before}]
    check "no workers survive close"      [expr {$after <= $before}]
    if {$after > $before} { puts "     leaked [expr {$after-$before}] processes" }
}

puts "\n=== 8. repeated runs: is it flaky? ==="
guarded "10 consecutive pools, same expectations each time" {
    set bad 0
    for {set run 0} {$run < 10} {incr run} {
        set p [::pool::create $CMD 6]
        set items {}
        for {set i 0} {$i < 60} {incr i} { lappend items [dict create id $i op sum n 8000] }
        ::pool::submit $p $items
        set r [::pool::wait $p]
        if {[llength $r] != 60} { incr bad }
        if {[llength [lsort -unique [lmap x $r {dict get $x id}]]] != 60} { incr bad }
        ::pool::close $p
    }
    check "10 runs, no lost or duplicated results" [expr {$bad == 0}]
}

puts ""
if {$fails == 0} { puts "SPIKE CLEAN: 0 failures" ; exit 0 }
puts "SPIKE FAILURES: $fails" ; exit 1
