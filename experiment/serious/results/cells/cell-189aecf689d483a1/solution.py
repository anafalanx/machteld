def sum_of_two_squares(n):
    if n < 0:
        return 0
    if n == 0:
        return 1

    # Factors of 2 cannot prevent a representation as two squares.
    while n % 2 == 0:
        n //= 2

    factor = 3
    while factor * factor <= n:
        odd_exponent = False
        while n % factor == 0:
            n //= factor
            odd_exponent = not odd_exponent

        if factor % 4 == 3 and odd_exponent:
            return 0
        factor += 2

    # Any remaining cofactor is prime and occurs to the first power.
    if n > 1 and n % 4 == 3:
        return 0
    return 1
