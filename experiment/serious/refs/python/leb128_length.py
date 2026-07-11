def leb128_length(n):
    if n == 0:
        return 1
    cnt = 0
    while n > 0:
        n >>= 7
        cnt += 1
    return cnt
