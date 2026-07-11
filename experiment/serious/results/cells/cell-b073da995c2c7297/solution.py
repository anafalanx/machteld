def gray_decode(g):
    n = g
    shifted = g >> 1
    while shifted != 0:
        n ^= shifted
        shifted >>= 1
    return n
