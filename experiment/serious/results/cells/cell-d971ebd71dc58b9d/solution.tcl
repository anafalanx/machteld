proc jacobi {a n} {
    set a [expr {(($a % $n) + $n) % $n}]
    set sign 1

    while {$a != 0} {
        while {($a & 1) == 0} {
            set a [expr {$a / 2}]
            set r [expr {$n % 8}]
            if {$r == 3 || $r == 5} {
                set sign [expr {-$sign}]
            }
        }

        if {($a % 4) == 3 && ($n % 4) == 3} {
            set sign [expr {-$sign}]
        }

        set oldA $a
        set a [expr {$n % $oldA}]
        set n $oldA
    }

    if {$n == 1} {
        return $sign
    }
    return 0
}
