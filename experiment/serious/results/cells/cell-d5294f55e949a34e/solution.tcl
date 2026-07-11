proc crt2_modnorm {value modulus} {
    set remainder [expr {$value % $modulus}]
    if {$remainder < 0} {
        set remainder [expr {$remainder + $modulus}]
    }
    return $remainder
}

proc crt2 {r1 m1 r2 m2} {
    if {$m1 <= 0 || $m2 <= 0} {
        return -1
    }

    set r1 [crt2_modnorm $r1 $m1]
    set r2 [crt2_modnorm $r2 $m2]

    # Euclid's algorithm for gcd(m1, m2).
    set a $m1
    set b $m2
    while {$b != 0} {
        set remainder [expr {$a % $b}]
        set a $b
        set b $remainder
    }
    set g $a

    set difference [expr {$r2 - $r1}]
    if {$difference % $g != 0} {
        return -1
    }

    set reducedM1 [expr {$m1 / $g}]
    set reducedM2 [expr {$m2 / $g}]

    if {$reducedM2 == 1} {
        set t 0
    } else {
        # Extended Euclid: oldCoefficient becomes the inverse of reducedM1
        # modulo reducedM2.
        set oldRemainder $reducedM1
        set newRemainder $reducedM2
        set oldCoefficient 1
        set newCoefficient 0
        while {$newRemainder != 0} {
            set quotient [expr {$oldRemainder / $newRemainder}]

            set nextRemainder [expr {$oldRemainder - $quotient * $newRemainder}]
            set oldRemainder $newRemainder
            set newRemainder $nextRemainder

            set nextCoefficient [expr {$oldCoefficient - $quotient * $newCoefficient}]
            set oldCoefficient $newCoefficient
            set newCoefficient $nextCoefficient
        }

        set inverse [crt2_modnorm $oldCoefficient $reducedM2]
        set factor [expr {$difference / $g}]
        set t [crt2_modnorm [expr {$factor * $inverse}] $reducedM2]
    }

    set lcm [expr {$reducedM1 * $m2}]
    return [crt2_modnorm [expr {$r1 + $m1 * $t}] $lcm]
}
