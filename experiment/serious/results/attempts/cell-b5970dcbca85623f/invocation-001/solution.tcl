proc collatz_max {n} {
    if {$n <= 0} {
        return 0
    }

    set current $n
    set maximum $n

    while {$current != 1} {
        if {$current % 2 == 0} {
            set current [expr {$current / 2}]
        } else {
            set current [expr {3 * $current + 1}]
        }

        if {$current > $maximum} {
            set maximum $current
        }
    }

    return $maximum
}
