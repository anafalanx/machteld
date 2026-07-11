proc __multiorder_gcd {x y} {
    while {$y != 0} {
        set remainder [expr {$x % $y}]
        set x $y
        set y $remainder
    }
    return $x
}

proc multiorder {a n} {
    if {$n <= 1} {
        return -1
    }

    set a [expr {(($a % $n) + $n) % $n}]
    if {[__multiorder_gcd $a $n] != 1} {
        return -1
    }

    set cur 1
    set order 0
    while {1} {
        set cur [expr {($cur * $a) % $n}]
        incr order
        if {$cur == 1} {
            return $order
        }
    }
}
