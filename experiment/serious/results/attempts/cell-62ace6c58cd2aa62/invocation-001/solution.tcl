proc sum_of_two_squares {n} {
    if {$n < 0} {
        return 0
    }
    if {$n == 0} {
        return 1
    }

    # Powers of two never obstruct a representation.
    while {$n % 2 == 0} {
        set n [expr {$n / 2}]
    }

    # All remaining possible factors are odd.  Checking p <= n / p
    # avoids computing a square-root and remains exact for integers.
    set p 3
    while {$p <= $n / $p} {
        if {$n % $p == 0} {
            set exponent 0
            while {$n % $p == 0} {
                set n [expr {$n / $p}]
                incr exponent
            }
            if {$p % 4 == 3 && $exponent % 2 == 1} {
                return 0
            }
        }
        incr p 2
    }

    # Any cofactor left here is prime and occurs to the first power.
    if {$n > 1 && $n % 4 == 3} {
        return 0
    }
    return 1
}
