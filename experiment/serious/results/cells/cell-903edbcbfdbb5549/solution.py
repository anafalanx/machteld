def modinv(a, m):
    if m <= 1:
        return -1

    a %= m
    old_r, r = a, m
    old_s, s = 1, 0

    while r != 0:
        quotient = old_r // r
        old_r, r = r, old_r - quotient * r
        old_s, s = s, old_s - quotient * s

    if old_r != 1:
        return -1
    return old_s % m
