proc fnv1a32 {n} {
    set u [expr {$n & 0xffffffffffffffff}]
    set h 2166136261

    for {set i 0} {$i < 8} {incr i} {
        set byte [expr {($u >> (8 * $i)) & 0xff}]
        set h [expr {(($h ^ $byte) * 16777619) & 0xffffffff}]
    }

    return $h
}
