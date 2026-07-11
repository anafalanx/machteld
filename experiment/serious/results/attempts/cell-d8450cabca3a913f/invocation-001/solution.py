def fnv1a32(n):
    u = n & 0xFFFFFFFFFFFFFFFF
    h = 2166136261

    for _ in range(8):
        h ^= u & 0xFF
        h = (h * 16777619) & 0xFFFFFFFF
        u >>= 8

    return h
