proc reverse_bits {n w} {
    set result 0
    for {set i 0} {$i < $w} {incr i} {
        set bit [expr {($n >> $i) & 1}]
        set result [expr {($result << 1) | $bit}]
    }
    return $result
}
