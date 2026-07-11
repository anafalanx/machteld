proc totient {n} {
    if {$n <= 0} { return -1 }
    set result $n
    set remaining $n
    set p 2
    while {$p * $p <= $remaining} {
        if {$remaining % $p == 0} {
            while {$remaining % $p == 0} {
                set remaining [expr {$remaining / $p}]
            }
            set result [expr {$result - $result / $p}]
        }
        incr p
    }
    if {$remaining > 1} {
        set result [expr {$result - $result / $remaining}]
    }
    return $result
}
