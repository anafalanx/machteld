proc isbn13_valid {n} {
    if {$n < 0 || $n > 9999999999999} {
        return 0
    }

    set sum 0
    set position 0
    while {1} {
        set digit [expr {$n % 10}]
        set weight [expr {$position % 2 == 0 ? 1 : 3}]
        set sum [expr {$sum + $digit * $weight}]
        incr position
        set n [expr {$n / 10}]
        if {$n == 0} {
            break
        }
    }
    return [expr {$sum % 10 == 0 ? 1 : 0}]
}
