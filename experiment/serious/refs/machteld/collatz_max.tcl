proc collatz_max {n} {
    if {$n <= 0} {
        return 0
    }

    set best $n
    while {$n != 1} {
        if {$n % 2 == 0} {
            set n [expr {$n / 2}]
        } else {
            set n [expr {3 * $n + 1}]
        }
        if {$n > $best} {
            set best $n
        }
    }
    return $best
}
