proc popcount {n} {
    set bits [expr {$n & 0xffffffffffffffff}]
    set count 0

    for {set i 0} {$i < 64} {incr i} {
        incr count [expr {$bits & 1}]
        set bits [expr {$bits >> 1}]
    }

    return $count
}
