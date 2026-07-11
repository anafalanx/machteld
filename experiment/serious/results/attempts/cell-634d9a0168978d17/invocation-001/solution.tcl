proc roman_value {n} {
    if {$n <= 0} {
        return -1
    }

    # Decode the packed symbol codes and apply the usual right-to-left rule.
    set symbolValues {0 1 5 10 50 100 500 1000}
    set rest $n
    set maximum 0
    set value 0
    while {$rest > 0} {
        set digit [expr {$rest % 10}]
        if {$digit < 1 || $digit > 7} {
            return -1
        }
        set symbol [lindex $symbolValues $digit]
        if {$symbol < $maximum} {
            set value [expr {$value - $symbol}]
        } else {
            set value [expr {$value + $symbol}]
            set maximum $symbol
        }
        set rest [expr {$rest / 10}]
    }

    if {$value < 1 || $value > 3999} {
        return -1
    }
    set result $value

    # Greedily regenerate the one canonical representation of the value.
    set tokenValues {1000 900 500 400 100 90 50 40 10 9 5 4 1}
    set tokenCodes  {7    57  6   56  5   35 4  34 3  13 2 12 1}
    set pack 0
    foreach tokenValue $tokenValues tokenCode $tokenCodes {
        while {$value >= $tokenValue} {
            set value [expr {$value - $tokenValue}]
            if {$tokenCode >= 10} {
                set pack [expr {$pack * 100 + $tokenCode}]
            } else {
                set pack [expr {$pack * 10 + $tokenCode}]
            }
        }
    }

    if {$pack != $n} {
        return -1
    }
    return $result
}
