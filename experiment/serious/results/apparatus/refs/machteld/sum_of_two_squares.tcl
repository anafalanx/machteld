proc sum_of_two_squares {n} {
    if {$n < 0} { return 0 }
    if {$n == 0} { return 1 }
    set p 2
    while {$p * $p <= $n} {
        if {$n % $p == 0} {
            set count 0
            while {$n % $p == 0} {
                set n [expr {$n / $p}]
                incr count
            }
            if {$p % 4 == 3 && $count % 2 == 1} { return 0 }
        }
        incr p
    }
    return [expr {$n > 1 && $n % 4 == 3 ? 0 : 1}]
}
