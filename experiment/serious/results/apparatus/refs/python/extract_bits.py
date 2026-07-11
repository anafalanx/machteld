def extract_bits(value, lo, width):
    raw = value & 0xFFFFFFFFFFFFFFFF
    if width == 0:
        return 0
    if width == 64:
        chunk = raw
    else:
        chunk = (raw >> lo) & ((1 << width) - 1)
    if chunk >= 1 << 63:
        chunk -= 1 << 64
    return chunk
