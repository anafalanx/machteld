def modinv(a, m):
    if m <= 1:
        return -1

    a %= m
    old_r, r = m, a
    old_x, x = 0, 1

    while r != 0:
        quotient = old_r // r
        old_r, r = r, old_r - quotient * r
        old_x, x = x, old_x - quotient * x

    if old_r != 1:
        return -1
    return old_x % m
