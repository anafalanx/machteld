proc upca_check {body} {
    if {$body < 0 || $body > 99999999999} {
        return -1
    }

    set total 0
    set remaining $body
    for {set i 0} {$i < 11} {incr i} {
        set digit [expr {$remaining % 10}]
        set weight [expr {$i % 2 == 0 ? 3 : 1}]
        set total [expr {$total + $weight * $digit}]
        set remaining [expr {$remaining / 10}]
    }

    return [expr {(10 - ($total % 10)) % 10}]
}
