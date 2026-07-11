def popcount(n):
    return bin(n & ((1 << 64) - 1)).count("1")
