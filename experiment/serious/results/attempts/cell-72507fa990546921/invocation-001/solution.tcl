proc extract_bits {value lo width} {
    if {$width == 0} {
        return 0
    }
    if {$width == 64} {
        return $value
    }

    set pattern [expr {$value & 0xffffffffffffffff}]
    set mask [expr {(1 << $width) - 1}]
    return [expr {($pattern >> $lo) & $mask}]
}
