def zigzag_encode(n):
    """Encode a signed integer using Protocol Buffers zigzag encoding."""
    return (n << 1) ^ (n >> 63)
