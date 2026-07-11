proc sum_of_two_squares {n} {
    if {$n < 0} {
        return 0
    }
    if {$n == 0} {
        return 1
    }

    set remaining $n
    set p 2

    while {$p * $p <= $remaining} {
        set exponent 0
        while {$remaining % $p == 0} {
            set remaining [expr {$remaining / $p}]
            incr exponent
        }

        if {$p % 4 == 3 && $exponent % 2 == 1} {
            return 0
        }

        if {$p == 2} {
            set p 3
        } else {
            incr p 2
        }
    }

    if {$remaining > 1 && $remaining % 4 == 3} {
        return 0
    }
    return 1
}
