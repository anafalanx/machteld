proc gcd {a b} {
    while {$b != 0} {
        set t [expr {$a % $b}]
        set a $b
        set b $t
    }
    return $a
}
