proc modinv {a m} {
    if {$m <= 1} { return -1 }
    set a [expr {$a % $m}]
    set old_r $a
    set r $m
    set old_s 1
    set s 0
    while {$r != 0} {
        set q [expr {$old_r / $r}]
        lassign [list $r [expr {$old_r - $q * $r}]] old_r r
        lassign [list $s [expr {$old_s - $q * $s}]] old_s s
    }
    if {$old_r != 1} { return -1 }
    return [expr {$old_s % $m}]
}
