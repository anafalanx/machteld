proc upca_check {body} {
    if {$body < 0 || $body > 99999999999} {
        return -1
    }

    set total 0
    set value $body
    for {set position 0} {$position < 11} {incr position} {
        set digit [expr {$value % 10}]
        set weight [expr {$position % 2 == 0 ? 3 : 1}]
        set total [expr {$total + $weight * $digit}]
        set value [expr {$value / 10}]
    }

    return [expr {(10 - ($total % 10)) % 10}]
}
