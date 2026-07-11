def _gcd(a, b):
    while b:
        a, b = b, a % b
    return a


def _inverse(a, modulus):
    """Return the inverse of a modulo modulus (the inputs are coprime)."""
    old_r, r = a, modulus
    old_s, s = 1, 0

    while r:
        quotient = old_r // r
        old_r, r = r, old_r - quotient * r
        old_s, s = s, old_s - quotient * s

    return old_s % modulus


def crt2(r1, m1, r2, m2):
    if m1 <= 0 or m2 <= 0:
        return -1

    r1 %= m1
    r2 %= m2

    g = _gcd(m1, m2)
    difference = r2 - r1
    if difference % g != 0:
        return -1

    reduced_m2 = m2 // g
    if reduced_m2 == 1:
        t = 0
    else:
        reduced_m1 = m1 // g
        inverse = _inverse(reduced_m1 % reduced_m2, reduced_m2)
        t = ((difference // g) * inverse) % reduced_m2

    lcm = (m1 // g) * m2
    return (r1 + m1 * t) % lcm
