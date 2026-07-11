def _extended_gcd(a, b):
    old_r, r = a, b
    old_s, s = 1, 0

    while r != 0:
        quotient = old_r // r
        old_r, r = r, old_r - quotient * r
        old_s, s = s, old_s - quotient * s

    return old_r, old_s


def crt2(r1, m1, r2, m2):
    if m1 <= 0 or m2 <= 0:
        return -1

    r1 %= m1
    r2 %= m2

    g, _ = _extended_gcd(m1, m2)
    difference = r2 - r1
    if difference % g != 0:
        return -1

    reduced_m1 = m1 // g
    reduced_m2 = m2 // g

    if reduced_m2 == 1:
        t = 0
    else:
        _, inverse = _extended_gcd(reduced_m1, reduced_m2)
        t = ((difference // g) * inverse) % reduced_m2

    lcm = reduced_m1 * m2
    return (r1 + m1 * t) % lcm
