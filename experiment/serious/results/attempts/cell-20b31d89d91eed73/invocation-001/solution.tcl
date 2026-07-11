proc gray_decode {g} {
    set n $g
    set s [expr {$g >> 1}]

    while {$s != 0} {
        set n [expr {$n ^ $s}]
        set s [expr {$s >> 1}]
    }

    return $n
}
