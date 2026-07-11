def reverse_bits(n, w):
    """Reverse the low ``w`` bits of ``n``."""
    value = n & ((1 << w) - 1)
    result = 0

    for _ in range(w):
        result = (result << 1) | (value & 1)
        value >>= 1

    return result
