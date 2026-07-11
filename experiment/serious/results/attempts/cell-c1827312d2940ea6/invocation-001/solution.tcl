proc sum_of_two_squares {n} {
    if {$n < 0} {
        return 0
    }
    if {$n == 0} {
        return 1
    }

    # Powers of two never affect representability.
    while {($n % 2) == 0} {
        set n [expr {$n / 2}]
    }

    # Any prime congruent to 3 modulo 4 must have an even exponent.
    for {set p 3} {$p * $p <= $n} {incr p 2} {
        set exponent 0
        while {($n % $p) == 0} {
            set n [expr {$n / $p}]
            incr exponent
        }
        if {($p % 4) == 3 && ($exponent % 2) == 1} {
            return 0
        }
    }

    # A remaining cofactor is prime and occurs to the first power.
    if {$n > 1 && ($n % 4) == 3} {
        return 0
    }
    return 1
}
