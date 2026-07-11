def leb128_length(n):
    count = 1
    while n > 127:
        n >>= 7
        count += 1
    return count
