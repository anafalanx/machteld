def isbn10_valid(body9, check):
    if body9 < 0 or body9 > 999999999:
        return 0
    if check < 0 or check > 10:
        return 0
    n = body9
    s = check
    w = 2
    while True:
        d = n % 10
        s += d * w
        w += 1
        n //= 10
        if n == 0:
            break
    return 1 if s % 11 == 0 else 0
