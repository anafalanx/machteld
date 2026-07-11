def modinv(a, m):
    if m <= 1:
        return -1

    a %= m
    old_r, r = m, a
    old_t, t = 0, 1

    while r != 0:
        quotient = old_r // r
        old_r, r = r, old_r - quotient * r
        old_t, t = t, old_t - quotient * t

    if old_r != 1:
        return -1
    return old_t % m
