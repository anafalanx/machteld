proc jacobi {a n} {
    # Normalize a first; this also makes a zero when n is 1.
    set a [expr {(($a % $n) + $n) % $n}]
    set sign 1

    while {$a != 0} {
        # Remove factors of two and apply (2/n).
        while {($a & 1) == 0} {
            set a [expr {$a / 2}]
            set residue [expr {$n % 8}]
            if {$residue == 3 || $residue == 5} {
                set sign [expr {-$sign}]
            }
        }

        # Quadratic reciprocity, followed by swapping numerator/modulus.
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
