# Handwritten alternatives for the two collection workloads. Keep public
# argument admission and text normalization the same as the candidate. The
# original Tcl functions and fixed answers continue to supply the oracles.
namespace eval ::checkedCollections {}

proc ::checkedCollections::histogram {words} {
    set words [::corpus::@rt::guard list<text> $words {$words}]
    set counts {}
    foreach word $words {
        set previous [dict getdef $counts [::corpus::@rt::mapTextKey $word] 0]
        set counts [dict replace $counts [::corpus::@rt::mapTextKey $word] [expr {$previous + 1}]]
    }
    return $counts
}

proc ::checkedCollections::merge_sorted {left right} {
    set left [::corpus::@rt::guard list<int> $left {$left}]
    set right [::corpus::@rt::guard list<int> $right {$right}]
    set leftCount [llength $left]
    set rightCount [llength $right]
    set i 0
    set j 0
    set merged {}
    while {$i < $leftCount && $j < $rightCount} {
        set items $left
        set index $i
        set a [expr {$index < 0 || $index >= [llength $items] ? 0 : [lindex $items $index]}]
        unset items index
        set items $right
        set index $j
        set b [expr {$index < 0 || $index >= [llength $items] ? 0 : [lindex $items $index]}]
        unset items index
        if {$a <= $b} {
            lappend merged $a
            incr i
        } else {
            lappend merged $b
            incr j
        }
    }
    while {$i < $leftCount} {
        set items $left
        set index $i
        set a [expr {$index < 0 || $index >= [llength $items] ? 0 : [lindex $items $index]}]
        unset items index
        lappend merged $a
        incr i
    }
    while {$j < $rightCount} {
        set items $right
        set index $j
        set b [expr {$index < 0 || $index >= [llength $items] ? 0 : [lindex $items $index]}]
        unset items index
        lappend merged $b
        incr j
    }
    return $merged
}
