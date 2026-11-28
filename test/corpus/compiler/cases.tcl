# Literal intake documents and their independently specified outcomes.
proc packetCases {} {
    return [list \
        {{"source":"雪","amount":17}} {some 17} \
        {{"source":"sensor","amount":-3,"adjustment":2}} {some -1} \
        {{"extra":[1,2],"amount":0,"source":"007"}} {some 0} \
        {{"source":"wide","amount":9007199254740993,"adjustment":1}} {some 9007199254740994} \
        {{"source":"sensor"}} none \
        {{"amount":5}} none \
        {{"source":"sensor","amount":"7"}} none \
        {{"source":"sensor","amount":7,"adjustment":null}} none \
        {{"source":"sensor","amount":1,"amount":2}} none \
        {{"source":"sensor","amount":1.0}} none \
        {[]} none \
        {bad-json} none]
}

# Each case supplies a Tcl argument list for one exported X function.
proc timedCases {} {
    set vocabulary {}
    foreach first {Amber amber Birch birch Cobalt cobalt Étain étain} {
        foreach second {north east south west red blue gold teal} {
            lappend vocabulary "$first-$second"
        }
    }
    set words {}
    for {set i 0} {$i < 4096} {incr i} {
        lappend words [lindex $vocabulary [expr {(37 * $i + 13 * ($i >> 6)) & 63}]]
    }
    set left {}
    set right {}
    for {set i 0} {$i < 512} {incr i} {
        lappend left [expr {4 * ($i / 3)}]
        lappend right [expr {3 * ($i / 2)}]
    }
    set ids {}
    set wide [expr {1 << 100}]
    for {set i 0} {$i < 1024} {incr i} {
        set group [expr {$i / 3}]
        set id [expr {$wide + $group}]
        lappend ids [expr {$group % 2 ? $id : -$id}]
    }
    set channels [list Amber amber "zero\x00tail" 雪 ""]
    set events {}
    for {set i 0} {$i < 480} {incr i} {
        set reading none
        if {$i % 9 != 0} {set reading [list some [expr {$i % 43 - 21}]]}
        lappend events [dict create tick [expr {$i / 3}] channel [lindex $channels [expr {$i % 5}]] reading $reading]
    }
    set postings {}
    set documents {}
    set packets [packetCases]
    for {set i 0} {$i < 32} {incr i} {
        lappend postings 9007199254740993.01 -0.03 -9007199254740993.00 -12.50 12.51
        foreach {wire expected} $packets {lappend documents $wire}
    }
    return [dict create gcd_sum {2048} escape_grid {32 24 32} histogram [list $words] \
        merge_sorted [list $left $right] fib {20} compact_ids [list $ids] \
        window_readings [list $events 雪 43 115] snapshot [list $events 101] \
        reconcile [list $postings] json_intake [list $documents]]
}

# Small fixed answers also guard the hand-written implementations.
proc goldenCases {} {
    set cases {
        gcd_sum {0} 0
        gcd_sum {10} 47
        escape_grid {4 3 8} {ok 62}
        escape_grid {3 2 0} {ok 0}
        histogram {{}} {}
        histogram {{007 7 007 A a}} {007 2 7 1 A 1 a 1}
        merge_sorted {{} {}} {}
        merge_sorted {{-4 1 1 8} {-4 0 2 8}} {-4 -4 0 1 1 2 8 8}
        merge_sorted {{} {-3 4}} {-3 4}
        fib {0} 0
        fib {10} 55
        compact_ids {{}} {}
        compact_ids {{0 0 -1 0 0}} {0 -1 0}
        reconcile {{}} {0 0 0}
        reconcile {{-0.00 0.1 0.20 -0.30}} {0 0 0.3}
        reconcile {{-9007199254740993.01 0.01 9007199254740993.00}} {0 -9007199254740993.01 0}
        reconcile {{9007199254740993.00 -9007199254740992.99 0.08 -0.01}} {0.08 0 9007199254740993}
        json_intake {{}} {}
    }
    set key "zero\x00tail"
    set big 340282366920938463463374607431768211456
    set next [expr {$big + 1}]
    lappend cases compact_ids [list [list $big $next $next $big]] [list $big $next $big]
    lappend cases histogram [list [list $key zero $key ""]] [dict create $key 2 zero 1 "" 1]
    set events [list \
        [dict create tick 2 channel $key reading {some 3}] \
        [dict create tick 2 channel $key reading {some -1}] \
        [dict create tick 3 channel $key reading none] \
        [dict create tick 4 channel 雪 reading {some 0}] \
        [dict create tick 5 channel $key reading {some 8}]]
    lappend cases window_readings [list $events $key 2 5] {3 -1}
    lappend cases window_readings [list $events $key 2 2] {}
    lappend cases snapshot [list $events 1] {}
    lappend cases snapshot [list $events 4] [dict create $key -1 雪 0]
    set docs {}
    set outcomes {}
    foreach {wire expected} [packetCases] {
        lappend docs $wire
        lappend outcomes $expected
    }
    lappend cases json_intake [list $docs] $outcomes
    return $cases
}
