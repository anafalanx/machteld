def _mod_pow(base, exponent, modulus):
    result = 1
    base %= modulus

    while exponent > 0:
        if exponent & 1:
            result = (result * base) % modulus
        base = (base * base) % modulus
        exponent >>= 1

    return result


def miller_rabin(n):
    if n < 2:
        return 0

    bases = (2, 3, 5, 7)
    for prime in bases:
        if n % prime == 0:
            return 1 if n == prime else 0

    d = n - 1
    r = 0
    while d % 2 == 0:
        d //= 2
        r += 1

    for base in bases:
        x = _mod_pow(base, d, n)
        if x == 1 or x == n - 1:
            continue

        for _ in range(r - 1):
            x = (x * x) % n
            if x == n - 1:
                break
        else:
            return 0

    return 1
