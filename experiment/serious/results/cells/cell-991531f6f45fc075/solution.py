MASK64 = (1 << 64) - 1


def extract_bits(value, lo, width):
    if width == 0:
        return 0
    if width == 64:
        return value

    logical_value = value & MASK64
    return (logical_value >> lo) & ((1 << width) - 1)
