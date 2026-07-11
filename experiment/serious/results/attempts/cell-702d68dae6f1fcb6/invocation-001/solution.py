def fnv1a32(n):
    u = n & ((1 << 64) - 1)
    h = 2166136261

    for shift in range(0, 64, 8):
        byte = (u >> shift) & 0xFF
        h ^= byte
        h = (h * 16777619) & 0xFFFFFFFF

    return h
