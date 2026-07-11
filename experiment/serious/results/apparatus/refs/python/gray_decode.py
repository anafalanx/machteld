def gray_decode(g):
    n = g
    s = g >> 1
    while s:
        n ^= s
        s >>= 1
    return n
