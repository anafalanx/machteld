proc crt2_gcd {a b} {
    while {$b != 0} {
        set remainder [expr {$a % $b}]
        set a $b
        set b $remainder
    }
    return $a
}

proc crt2_inverse {a modulus} {
    # Track only the Bezout coefficient of a.  The caller guarantees that
    # a and modulus are coprime.
    set oldR $a
    set r $modulus
    set oldS 1
    set s 0

    while {$r != 0} {
        set quotient [expr {$oldR / $r}]

        set nextR [expr {$oldR - $quotient * $r}]
        set oldR $r
        set r $nextR

        set nextS [expr {$oldS - $quotient * $s}]
        set oldS $s
        set s $nextS
    }

    return [expr {(($oldS % $modulus) + $modulus) % $modulus}]
}

proc crt2 {r1 m1 r2 m2} {
    if {$m1 <= 0 || $m2 <= 0} {
        return -1
    }

    set r1 [expr {(($r1 % $m1) + $m1) % $m1}]
    set r2 [expr {(($r2 % $m2) + $m2) % $m2}]
    set g [crt2_gcd $m1 $m2]
    set difference [expr {$r2 - $r1}]

    if {$difference % $g != 0} {
        return -1
    }

    set reducedM1 [expr {$m1 / $g}]
    set reducedM2 [expr {$m2 / $g}]
    set lcm [expr {$reducedM1 * $m2}]

    if {$reducedM2 == 1} {
        set t 0
    } else {
        set inverse [crt2_inverse $reducedM1 $reducedM2]
        set factor [expr {$difference / $g}]
        set t [expr {(($factor * $inverse) % $reducedM2 + $reducedM2) % $reducedM2}]
    }

    set x [expr {$r1 + $m1 * $t}]
    return [expr {(($x % $lcm) + $lcm) % $lcm}]
}
