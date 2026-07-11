def gray_decode(g):
    n = g
    s = g >> 1
    while s != 0:
        n ^= s
        s >>= 1
    return n
