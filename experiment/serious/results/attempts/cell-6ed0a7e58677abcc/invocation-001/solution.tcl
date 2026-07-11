proc totient {n} {
    if {$n <= 0} {
        return -1
    }

    set result $n
    set nn $n
    set p 2

    while {$p * $p <= $nn} {
        if {$nn % $p == 0} {
            while {$nn % $p == 0} {
                set nn [expr {$nn / $p}]
            }
            set result [expr {$result - $result / $p}]
        }

        if {$p == 2} {
            set p 3
        } else {
            incr p 2
        }
    }

    if {$nn > 1} {
        set result [expr {$result - $result / $nn}]
    }

    return $result
}
