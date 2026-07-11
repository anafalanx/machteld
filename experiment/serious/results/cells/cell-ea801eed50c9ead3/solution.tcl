proc collatz_max {n} {
    if {$n <= 0} {
        return 0
    }

    set current $n
    set largest $n
    while {$current != 1} {
        if {$current % 2 == 0} {
            set current [expr {$current / 2}]
        } else {
            set current [expr {3 * $current + 1}]
        }

        if {$current > $largest} {
            set largest $current
        }
    }

    return $largest
}
