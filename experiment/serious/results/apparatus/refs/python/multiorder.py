import math

def multiorder(a, n):
    if n <= 1:
        return -1
    a %= n
    if a < 0:
        a += n
    if math.gcd(a, n) != 1:
        return -1
    k = 1
    cur = a % n
    while cur != 1:
        cur = (cur * a) % n
        k += 1
    return k
