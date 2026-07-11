proc fnv1a32 {n} {
    set raw [expr {$n & 0xffffffffffffffff}]
    set hash 2166136261
    for {set i 0} {$i < 8} {incr i} {
        set byte [expr {($raw >> (8 * $i)) & 0xff}]
        set hash [expr {(($hash ^ $byte) * 16777619) & 0xffffffff}]
    }
    return $hash
}
