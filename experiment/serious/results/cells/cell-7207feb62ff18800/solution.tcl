proc bracket_balanced {n length} {
    if {$length < 0} {
        return 0
    }

    set depth 0
    set bits $n
    for {set i 0} {$i < $length} {incr i} {
        if {$bits & 1} {
            incr depth -1
            if {$depth < 0} {
                return 0
            }
        } else {
            incr depth
        }
        set bits [expr {$bits >> 1}]
    }

    return [expr {$depth == 0 ? 1 : 0}]
}
