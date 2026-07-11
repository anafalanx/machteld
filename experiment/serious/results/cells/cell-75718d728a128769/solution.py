def reverse_bits(n, w):
    value = n & ((1 << w) - 1)
    result = 0

    for _ in range(w):
        result = (result << 1) | (value & 1)
        value >>= 1

    return result
