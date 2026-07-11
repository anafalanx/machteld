from math import gcd


def multiorder(a, n):
    if n <= 1:
        return -1

    a %= n
    if gcd(a, n) != 1:
        return -1

    cur = a
    order = 1
    while cur != 1:
        cur = (cur * a) % n
        order += 1
    return order
