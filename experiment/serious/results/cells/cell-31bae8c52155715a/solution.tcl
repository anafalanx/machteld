proc isbn13_valid {n} {
    if {$n < 0 || $n > 9999999999999} {
        return 0
    }

    set sum 0
    set weight 1
    set remaining $n
    for {set i 0} {$i < 13} {incr i} {
        set digit [expr {$remaining % 10}]
        set sum [expr {$sum + $weight * $digit}]
        set remaining [expr {$remaining / 10}]
        set weight [expr {4 - $weight}]
    }

    return [expr {$sum % 10 == 0 ? 1 : 0}]
}
