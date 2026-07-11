proc roman_value {n} {
    if {$n <= 0} { return -1 }
    set symbols {1 1 2 5 3 10 4 50 5 100 6 500 7 1000}
    set codes {}
    set m $n
    while {$m > 0} {
        lappend codes [expr {$m % 10}]
        set m [expr {$m / 10}]
    }
    set codes [lreverse $codes]
    foreach code $codes {
        if {$code < 1 || $code > 7} { return -1 }
    }
    set total 0
    set previous 0
    foreach code [lreverse $codes] {
        set value [dict get $symbols $code]
        if {$value < $previous} {
            incr total [expr {-$value}]
        } else {
            incr total $value
            set previous $value
        }
    }
    if {$total < 1 || $total > 3999} { return -1 }
    set canonical {
        1000 {7} 900 {5 7} 500 {6} 400 {5 6} 100 {5} 90 {3 5}
        50 {4} 40 {3 4} 10 {3} 9 {1 3} 5 {2} 4 {1 2} 1 {1}
    }
    set remain $total
    set out {}
    foreach {value emitted} $canonical {
        while {$remain >= $value} {
            lappend out {*}$emitted
            incr remain [expr {-$value}]
        }
    }
    set packed 0
    foreach code $out {
        set packed [expr {$packed * 10 + $code}]
    }
    return [expr {$packed == $n ? $total : -1}]
}
