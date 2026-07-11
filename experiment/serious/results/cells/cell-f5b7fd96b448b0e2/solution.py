def zigzag_encode(n):
    return (n << 1) ^ (n >> 63)
