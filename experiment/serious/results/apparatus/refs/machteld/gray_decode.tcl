proc gray_decode {g} {
    set value $g
    set shifted [expr {$g >> 1}]
    while {$shifted != 0} {
        set value [expr {$value ^ $shifted}]
        set shifted [expr {$shifted >> 1}]
    }
    return $value
}
