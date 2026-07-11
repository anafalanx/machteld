proc bracket_balanced {n length} {
    if {$length < 0} {
        return 0
    }

    set depth 0
    for {set i 0} {$i < $length} {incr i} {
        if {(($n >> $i) & 1) == 0} {
            incr depth
        } else {
            incr depth -1
            if {$depth < 0} {
                return 0
            }
        }
    }

    return [expr {$depth == 0 ? 1 : 0}]
}
