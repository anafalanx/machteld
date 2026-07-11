proc upca_check {body11} {
    if {$body11 < 0 || $body11 > 99999999999} { return -1 }
    set sum 0
    set index 0
    while {1} {
        set digit [expr {$body11 % 10}]
        set weight [expr {$index % 2 == 0 ? 3 : 1}]
        incr sum [expr {$digit * $weight}]
        incr index
        set body11 [expr {$body11 / 10}]
        if {$body11 == 0} { break }
    }
    return [expr {(10 - ($sum % 10)) % 10}]
}
