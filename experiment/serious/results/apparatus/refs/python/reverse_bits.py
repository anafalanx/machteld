def reverse_bits(n, w):
    r = 0
    for i in range(w):
        bit = (n >> i) & 1
        r |= bit << (w - 1 - i)
    return r
