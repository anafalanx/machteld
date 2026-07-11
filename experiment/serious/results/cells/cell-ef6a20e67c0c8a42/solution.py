def jacobi(a, n):
    a %= n
    sign = 1

    while a != 0:
        while a % 2 == 0:
            a //= 2
            if n % 8 in (3, 5):
                sign = -sign

        if a % 4 == 3 and n % 4 == 3:
            sign = -sign

        a, n = n % a, a

    return sign if n == 1 else 0
