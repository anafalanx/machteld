proc crt2 {r1 m1 r2 m2} {
    if {$m1 <= 0 || $m2 <= 0} {
        return -1
    }

    set r1 [expr {$r1 % $m1}]
    if {$r1 < 0} { set r1 [expr {$r1 + $m1}] }
    set r2 [expr {$r2 % $m2}]
    if {$r2 < 0} { set r2 [expr {$r2 + $m2}] }

    set a $m1
    set b $m2
    while {$b != 0} {
        set remainder [expr {$a % $b}]
        set a $b
        set b $remainder
    }
    set g $a

    set delta [expr {$r2 - $r1}]
    if {$delta % $g != 0} {
        return -1
    }

    set m2g [expr {$m2 / $g}]
    set lcm [expr {($m1 / $g) * $m2}]
    set diff [expr {$delta / $g}]

    # Extended Euclid: inverse of (m1/g) modulo (m2/g).
    set old_r [expr {($m1 / $g) % $m2g}]
    set r $m2g
    set old_s 1
    set s 0
    while {$r != 0} {
        set q [expr {$old_r / $r}]
        set next_r [expr {$old_r - $q * $r}]
        set old_r $r
        set r $next_r
        set next_s [expr {$old_s - $q * $s}]
        set old_s $s
        set s $next_s
    }
    set inv [expr {$old_s % $m2g}]
    if {$inv < 0} { set inv [expr {$inv + $m2g}] }

    set diff_mod [expr {$diff % $m2g}]
    if {$diff_mod < 0} { set diff_mod [expr {$diff_mod + $m2g}] }
    set t [expr {($diff_mod * $inv) % $m2g}]
    set x [expr {($r1 + $m1 * $t) % $lcm}]
    if {$x < 0} { set x [expr {$x + $lcm}] }
    return $x
}
