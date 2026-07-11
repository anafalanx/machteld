def popcount(n):
    value = n & ((1 << 64) - 1)
    count = 0

    for _ in range(64):
        count += value & 1
        value >>= 1

    return count
