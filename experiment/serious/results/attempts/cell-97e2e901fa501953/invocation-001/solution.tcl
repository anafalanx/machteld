proc mod97_checkdigits {n} {
    if {$n < 0 || $n > 999999999999999999} {
        return -1
    }

    set r [expr {(($n % 97) * 100) % 97}]
    return [expr {(1 - $r + 97) % 97}]
}
