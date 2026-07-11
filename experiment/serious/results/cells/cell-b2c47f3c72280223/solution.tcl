proc mr_powmod {base exponent modulus} {
    set result 1
    set base [expr {$base % $modulus}]

    while {$exponent > 0} {
        if {($exponent & 1) != 0} {
            set result [expr {($result * $base) % $modulus}]
        }
        set exponent [expr {$exponent >> 1}]
        set base [expr {($base * $base) % $modulus}]
    }

    return $result
}

proc miller_rabin {n} {
    if {$n < 2} {
        return 0
    }

    foreach p {2 3 5 7} {
        if {($n % $p) == 0} {
            return [expr {$n == $p ? 1 : 0}]
        }
    }

    set d [expr {$n - 1}]
    set r 0
    while {($d & 1) == 0} {
        set d [expr {$d >> 1}]
        incr r
    }

    foreach a {2 3 5 7} {
        set x [mr_powmod $a $d $n]
        if {$x == 1 || $x == ($n - 1)} {
            continue
        }

        set witnessedComposite 1
        for {set i 1} {$i < $r} {incr i} {
            set x [expr {($x * $x) % $n}]
            if {$x == ($n - 1)} {
                set witnessedComposite 0
                break
            }
        }

        if {$witnessedComposite} {
            return 0
        }
    }

    return 1
}
