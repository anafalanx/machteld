def popcount(n):
    bits = n & ((1 << 64) - 1)
    count = 0

    for _ in range(64):
        count += bits & 1
        bits >>= 1

    return count
