proc popcount {n} {
    set value [expr {$n & 0xffffffffffffffff}]
    set count 0
    for {set i 0} {$i < 64} {incr i} {
        incr count [expr {$value & 1}]
        set value [expr {$value >> 1}]
    }
    return $count
}
