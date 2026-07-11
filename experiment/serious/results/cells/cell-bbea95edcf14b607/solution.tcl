proc zigzag_decode {u} {
    return [expr {($u >> 1) ^ (-($u & 1))}]
}
