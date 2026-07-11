proc roman_value {n} {
    if {$n <= 0} {
        return -1
    }

    set rest $n
    set maximum 0
    set value 0
    set symbolValues {0 1 5 10 50 100 500 1000}

    while {$rest > 0} {
        set code [expr {$rest % 10}]
        if {$code < 1 || $code > 7} {
            return -1
        }

        set symbolValue [lindex $symbolValues $code]
        if {$symbolValue < $maximum} {
            set value [expr {$value - $symbolValue}]
        } else {
            set value [expr {$value + $symbolValue}]
            set maximum $symbolValue
        }
        set rest [expr {$rest / 10}]
    }

    if {$value < 1 || $value > 3999} {
        return -1
    }

    set remaining $value
    set packed 0
    foreach {amount codes} {
        1000 7
        900  57
        500  6
        400  56
        100  5
        90   35
        50   4
        40   34
        10   3
        9    13
        5    2
        4    12
        1    1
    } {
        while {$remaining >= $amount} {
            if {$codes >= 10} {
                set packed [expr {$packed * 100 + $codes}]
            } else {
                set packed [expr {$packed * 10 + $codes}]
            }
            set remaining [expr {$remaining - $amount}]
        }
    }

    if {$packed != $n} {
        return -1
    }
    return $value
}
