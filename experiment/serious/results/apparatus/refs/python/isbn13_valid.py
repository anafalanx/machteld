def isbn13_valid(n):
    if n < 0 or n > 9999999999999:
        return 0
    s = 0
    cnt = 0
    while True:
        d = n % 10
        w = 1 if cnt % 2 == 0 else 3
        s += d * w
        cnt += 1
        n //= 10
        if n == 0:
            break
    return 1 if s % 10 == 0 else 0
