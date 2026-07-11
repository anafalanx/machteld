proc reverse_bits {n w} {
    set bits [expr {$n & ((1 << $w) - 1)}]
    set result 0

    for {set i 0} {$i < $w} {incr i} {
        set result [expr {($result << 1) | ($bits & 1)}]
        set bits [expr {$bits >> 1}]
    }

    return $result
}
