def miller_rabin(n):
    if n < 2:
        return 0
    for p in (2, 3, 5, 7):
        if n % p == 0:
            return 1 if n == p else 0
    d = n - 1
    r = 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for a in (2, 3, 5, 7):
        if a % n == 0:
            continue
        x = pow(a, d, n)
        if x == 1 or x == n - 1:
            continue
        witness = True
        for _ in range(r - 1):
            x = (x * x) % n
            if x == n - 1:
                witness = False
                break
        if witness:
            return 0
    return 1
