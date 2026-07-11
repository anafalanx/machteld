proc luhn_valid {n} {
    if {$n < 0} {
        return 0
    }

    set sum 0
    set double 0
    set remaining $n

    while {$remaining > 0} {
        set digit [expr {$remaining % 10}]
        if {$double} {
            set digit [expr {$digit * 2}]
            if {$digit > 9} {
                incr digit -9
            }
        }
        incr sum $digit
        set remaining [expr {$remaining / 10}]
        set double [expr {!$double}]
    }

    return [expr {$sum % 10 == 0 ? 1 : 0}]
}
