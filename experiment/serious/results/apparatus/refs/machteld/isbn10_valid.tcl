proc isbn10_valid {body9 check} {
    if {$body9 < 0 || $body9 > 999999999 || $check < 0 || $check > 10} {
        return 0
    }

    set sum $check
    set weight 2
    while {1} {
        set digit [expr {$body9 % 10}]
        set sum [expr {$sum + $digit * $weight}]
        incr weight
        set body9 [expr {$body9 / 10}]
        if {$body9 == 0} {
            break
        }
    }
    return [expr {$sum % 11 == 0 ? 1 : 0}]
}
