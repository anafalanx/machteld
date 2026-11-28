# Ordinary Tcl implementation for the same valid input rows as the X timing
# fixture. The independent oracle in probe-window.tcl enumerates clock ticks.
namespace eval ::handProbe {}

proc ::handProbe::compareStart {a b} {
    set x [lindex $a 0]
    set y [lindex $b 0]
    return [expr {($x > $y) - ($x < $y)}]
}

proc ::handProbe::research {runs north south bench start stop} {
    set selected {}
    foreach row $runs {
        if {[dict get $row bench] ne $bench} continue
        set lo [expr {max($start, [dict get $row start])}]
        set hi [expr {min($stop, [dict get $row stop])}]
        if {$lo < $hi} {dict set selected [dict get $row id] [list $lo $hi]}
    }

    set coverage {}
    set probes {}
    set evidence 0
    foreach feed [list $north $south] {
        set seen {}
        foreach row $feed {
            set id [dict get $row id]
            if {[dict exists $seen $id]} {
                set previous [dict get $seen $id]
                foreach field {run probe start stop} {
                    if {[dict get $previous $field] ne [dict get $row $field]} {
                        return [list err [dict create message "source reused evidence id '$id' with different content"]]
                    }
                }
                continue
            }
            dict set seen $id $row
            set run [dict get $row run]
            if {![dict exists $selected $run]} continue
            lassign [dict get $selected $run] lo hi
            set first [expr {max($lo, [dict get $row start])}]
            set last [expr {min($hi, [dict get $row stop])}]
            if {$first >= $last} continue
            incr evidence
            dict set probes [dict get $row probe] 1
            # Use offsets so Tcl's fast integer sort also handles narrow windows
            # on clocks whose absolute timestamps exceed a machine integer.
            dict lappend coverage $run [list [expr {$first-$lo}] [expr {$last-$lo}]]
        }
    }

    set ids [lsort -ascii [dict keys $selected]]
    set gaps {}
    foreach id $ids {
        lassign [dict get $selected $id] lo hi
        set intervals [dict getdef $coverage $id {}]
        if {$hi-$lo <= 0x7fffffffffffffff} {
            set intervals [lsort -integer -index 0 $intervals]
        } else {
            set intervals [lsort -command ::handProbe::compareStart $intervals]
        }
        set cursor 0
        foreach span $intervals {
            lassign $span a b
            if {$a > $cursor} {
                lappend gaps [dict create run $id start [expr {$lo+$cursor}] stop [expr {$lo+$a}]]
            }
            if {$b > $cursor} {set cursor $b}
        }
        if {$lo+$cursor < $hi} {lappend gaps [dict create run $id start [expr {$lo+$cursor}] stop $hi]}
    }
    return [list ok [dict create runs $ids probes [lsort -ascii [dict keys $probes]] gaps $gaps evidence $evidence]]
}
