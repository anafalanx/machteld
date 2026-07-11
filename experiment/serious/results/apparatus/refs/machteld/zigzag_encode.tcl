proc zigzag_encode {n} {
    return [expr {($n << 1) ^ ($n >> 63)}]
}
