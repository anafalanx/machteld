proc multiorder {a n} {
    if {$n <= 1} { return -1 }
    set a [expr {$a % $n}]
    set x $a
    set y $n
    while {$y != 0} {
        set t [expr {$x % $y}]
        set x $y
        set y $t
    }
    if {$x != 1} { return -1 }
    set k 1
    set current $a
    while {$current != 1} {
        set current [expr {($current * $a) % $n}]
        incr k
    }
    return $k
}
