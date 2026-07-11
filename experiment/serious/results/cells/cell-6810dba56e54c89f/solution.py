def jacobi(a, n):
    """Return the Jacobi symbol (a/n) for positive odd n."""
    a %= n
    sign = 1

    while a != 0:
        while a % 2 == 0:
            a //= 2
            if n % 8 == 3 or n % 8 == 5:
                sign = -sign

        if a % 4 == 3 and n % 4 == 3:
            sign = -sign

        a, n = n % a, a

    return sign if n == 1 else 0
