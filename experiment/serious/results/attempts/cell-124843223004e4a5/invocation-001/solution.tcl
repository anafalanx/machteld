proc isbn10_valid {body check} {
    if {$body < 0 || $body > 999999999 || $check < 0 || $check > 10} {
        return 0
    }

    set sum $check
    set remaining $body
    for {set weight 2} {$weight <= 10} {incr weight} {
        set digit [expr {$remaining % 10}]
        set sum [expr {$sum + $weight * $digit}]
        set remaining [expr {$remaining / 10}]
    }

    return [expr {$sum % 11 == 0 ? 1 : 0}]
}
