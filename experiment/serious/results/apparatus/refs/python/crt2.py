import math

def crt2(r1, m1, r2, m2):
    if m1 <= 0 or m2 <= 0:
        return -1
    r1 %= m1
    r2 %= m2
    g = math.gcd(m1, m2)
    if (r2 - r1) % g != 0:
        return -1
    lcm = m1 // g * m2
    diff = (r2 - r1) // g
    m2g = m2 // g
    a = (m1 // g) % m2g
    a %= m2g
    # extended-euclid inverse of a mod m2g
    old_r, r = a, m2g
    old_s, s = 1, 0
    while r != 0:
        q = old_r // r
        old_r, r = r, old_r - q * r
        old_s, s = s, old_s - q * s
    inv = old_s % m2g
    t = (diff % m2g) * inv % m2g
    x = (r1 + m1 * t) % lcm
    if x < 0:
        x += lcm
    return x
