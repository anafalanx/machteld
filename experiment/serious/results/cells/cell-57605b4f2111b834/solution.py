def zigzag_decode(u):
    return (u >> 1) ^ (-(u & 1))
