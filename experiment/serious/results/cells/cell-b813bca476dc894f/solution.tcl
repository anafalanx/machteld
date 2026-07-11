proc modinv {a m} {
    if {$m <= 1} {
        return -1
    }

    set a [expr {(($a % $m) + $m) % $m}]
    if {$a == 0} {
        return -1
    }

    set oldR $m
    set r $a
    set oldT 0
    set t 1

    while {$r != 0} {
        set quotient [expr {$oldR / $r}]

        set nextR [expr {$oldR - $quotient * $r}]
        set oldR $r
        set r $nextR

        set nextT [expr {$oldT - $quotient * $t}]
        set oldT $t
        set t $nextT
    }

    if {$oldR != 1} {
        return -1
    }

    return [expr {(($oldT % $m) + $m) % $m}]
}
