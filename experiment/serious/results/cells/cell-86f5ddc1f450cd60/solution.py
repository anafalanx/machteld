def totient(n):
    if n <= 0:
        return -1

    result = n
    nn = n
    p = 2

    while p * p <= nn:
        if nn % p == 0:
            while nn % p == 0:
                nn //= p
            result -= result // p
        p = 3 if p == 2 else p + 2

    if nn > 1:
        result -= result // nn

    return result
