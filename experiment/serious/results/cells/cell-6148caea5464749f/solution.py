MASK64 = (1 << 64) - 1


def extract_bits(value, lo, width):
    if width == 0:
        return 0
    if width == 64:
        return value

    return ((value & MASK64) >> lo) & ((1 << width) - 1)
