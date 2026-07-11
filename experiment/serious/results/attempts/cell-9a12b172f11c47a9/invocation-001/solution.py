def totient(n):
    if n <= 0:
        return -1

    result = n
    remaining = n
    divisor = 2

    while divisor * divisor <= remaining:
        if remaining % divisor == 0:
            while remaining % divisor == 0:
                remaining //= divisor
            result -= result // divisor

        divisor = 3 if divisor == 2 else divisor + 2

    if remaining > 1:
        result -= result // remaining

    return result
