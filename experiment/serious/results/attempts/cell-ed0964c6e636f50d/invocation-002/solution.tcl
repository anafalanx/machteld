proc roman_value {n} {
    if {$n <= 0} {
        return -1
    }

    set rest $n
    set total 0
    set maximum 0
    while {$rest > 0} {
        set code [expr {$rest % 10}]
        set rest [expr {$rest / 10}]

        switch $code {
            1 { set value 1 }
            2 { set value 5 }
            3 { set value 10 }
            4 { set value 50 }
            5 { set value 100 }
            6 { set value 500 }
            7 { set value 1000 }
            default { return -1 }
        }

        if {$value < $maximum} {
            set total [expr {$total - $value}]
        } else {
            set total [expr {$total + $value}]
            set maximum $value
        }
    }

    if {$total < 1 || $total > 3999} {
        return -1
    }

    set remaining $total
    set packed 0
    foreach value {1000 900 500 400 100 90 50 40 10 9 5 4 1} codes {7 57 6 56 5 35 4 34 3 13 2 12 1} {
        while {$remaining >= $value} {
            foreach code [split $codes {}] {
                set packed [expr {$packed * 10 + $code}]
            }
            set remaining [expr {$remaining - $value}]
        }
    }

    if {$packed != $n} {
        return -1
    }
    return $total
}
