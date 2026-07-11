proc totient {n} {
    if {$n <= 0} {
        return -1
    }

    set result $n
    set nn $n

    if {$nn % 2 == 0} {
        set result [expr {$result - $result / 2}]
        while {$nn % 2 == 0} {
            set nn [expr {$nn / 2}]
        }
    }

    for {set p 3} {$p * $p <= $nn} {incr p 2} {
        if {$nn % $p == 0} {
            set result [expr {$result - $result / $p}]
            while {$nn % $p == 0} {
                set nn [expr {$nn / $p}]
            }
        }
    }

    if {$nn > 1} {
        set result [expr {$result - $result / $nn}]
    }

    return $result
}
