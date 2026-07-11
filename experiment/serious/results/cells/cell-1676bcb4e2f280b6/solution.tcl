proc zigzag_encode {n} {
    return [expr {$n < 0 ? -2 * $n - 1 : 2 * $n}]
}
