proc leb128_length {n} {
    set count 1
    while {$n > 127} {
        set n [expr {$n >> 7}]
        incr count
    }
    return $count
}
