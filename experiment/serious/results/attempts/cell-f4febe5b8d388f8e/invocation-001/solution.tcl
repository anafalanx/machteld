proc multiorder {a n} {
    if {$n <= 1} {
        return -1
    }

    set a [expr {$a % $n}]
    if {$a < 0} {
        set a [expr {$a + $n}]
    }

    set x $a
    set y $n
    while {$y != 0} {
        set remainder [expr {$x % $y}]
        set x $y
        set y $remainder
    }
    if {$x != 1} {
        return -1
    }

    set cur 1
    set k 0
    while {1} {
        set cur [expr {($cur * $a) % $n}]
        incr k
        if {$cur == 1} {
            return $k
        }
    }
}
