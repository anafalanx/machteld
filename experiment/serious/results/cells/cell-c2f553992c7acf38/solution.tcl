proc upca_check {body} {
    if {$body < 0 || $body > 99999999999} {
        return -1
    }

    set n $body
    set total 0
    set weight 3

    for {set i 0} {$i < 11} {incr i} {
        set digit [expr {$n % 10}]
        set total [expr {$total + $weight * $digit}]
        set n [expr {$n / 10}]
        set weight [expr {4 - $weight}]
    }

    return [expr {(10 - ($total % 10)) % 10}]
}
