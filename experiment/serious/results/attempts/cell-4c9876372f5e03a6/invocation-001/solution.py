from math import gcd


def multiorder(a, n):
    if n <= 1:
        return -1

    a %= n
    if gcd(a, n) != 1:
        return -1

    cur = 1
    order = 0
    while True:
        cur = (cur * a) % n
        order += 1
        if cur == 1:
            return order
