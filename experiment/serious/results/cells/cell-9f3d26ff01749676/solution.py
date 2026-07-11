def sum_of_two_squares(n):
    if n < 0:
        return 0
    if n == 0:
        return 1

    # Powers of two never obstruct a sum-of-two-squares representation.
    while n % 2 == 0:
        n //= 2

    factor = 3
    while factor * factor <= n:
        exponent = 0
        while n % factor == 0:
            n //= factor
            exponent += 1

        if factor % 4 == 3 and exponent % 2 == 1:
            return 0

        factor += 2

    # Any remaining cofactor is prime and occurs to the first power.
    if n > 1 and n % 4 == 3:
        return 0
    return 1
