proc luhn_valid {n} {
    if {$n < 0} {
        return 0
    }

    set sum 0
    set position 0
    while {1} {
        set digit [expr {$n % 10}]
        if {$position % 2 == 1} {
            set digit [expr {$digit * 2}]
            if {$digit > 9} {
                incr digit -9
            }
        }
        incr sum $digit
        incr position
        set n [expr {$n / 10}]
        if {$n == 0} {
            break
        }
    }
    return [expr {$sum % 10 == 0 ? 1 : 0}]
}
