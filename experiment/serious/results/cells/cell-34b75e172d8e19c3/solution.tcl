proc isbn13_valid {n} {
    if {$n < 0 || $n > 9999999999999} {
        return 0
    }

    set sum 0
    set weight 1
    for {set i 0} {$i < 13} {incr i} {
        set digit [expr {$n % 10}]
        set sum [expr {$sum + $weight * $digit}]
        set n [expr {$n / 10}]
        set weight [expr {4 - $weight}]
    }

    return [expr {$sum % 10 == 0 ? 1 : 0}]
}
