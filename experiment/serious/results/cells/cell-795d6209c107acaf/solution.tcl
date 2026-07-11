proc mr_modpow {base exponent modulus} {
    set result 1
    set base [expr {$base % $modulus}]

    while {$exponent > 0} {
        if {$exponent & 1} {
            set result [expr {($result * $base) % $modulus}]
        }
        set exponent [expr {$exponent >> 1}]
        if {$exponent > 0} {
            set base [expr {($base * $base) % $modulus}]
        }
    }

    return $result
}

proc miller_rabin {n} {
    if {$n < 2} {
        return 0
    }

    foreach p {2 3 5 7} {
        if {$n % $p == 0} {
            return [expr {$n == $p ? 1 : 0}]
        }
    }

    set d [expr {$n - 1}]
    set r 0
    while {$d % 2 == 0} {
        set d [expr {$d / 2}]
        incr r
    }

    foreach a {2 3 5 7} {
        set x [mr_modpow $a $d $n]
        if {$x == 1 || $x == $n - 1} {
            continue
        }

        set passed 0
        for {set i 1} {$i < $r} {incr i} {
            set x [expr {($x * $x) % $n}]
            if {$x == $n - 1} {
                set passed 1
                break
            }
        }

        if {!$passed} {
            return 0
        }
    }

    return 1
}
