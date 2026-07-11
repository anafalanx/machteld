proc totient {n} {
    if {$n <= 0} {
        return -1
    }

    set result $n
    set nn $n

    for {set p 2} {$p * $p <= $nn} {incr p} {
        if {$nn % $p == 0} {
            while {$nn % $p == 0} {
                set nn [expr {$nn / $p}]
            }
            set result [expr {$result - $result / $p}]
        }
    }

    if {$nn > 1} {
        set result [expr {$result - $result / $nn}]
    }

    return $result
}
