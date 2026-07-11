proc isbn13_valid {n} {
    if {$n < 0 || $n > 9999999999999} {
        return 0
    }

    set value $n
    set sum 0
    set weight 1

    for {set position 0} {$position < 13} {incr position} {
        set digit [expr {$value % 10}]
        set sum [expr {$sum + $weight * $digit}]
        set value [expr {$value / 10}]
        set weight [expr {4 - $weight}]
    }

    return [expr {$sum % 10 == 0 ? 1 : 0}]
}
