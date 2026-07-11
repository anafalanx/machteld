def sum_of_two_squares(n):
    if n < 0:
        return 0
    if n == 0:
        return 1
    p = 2
    while p * p <= n:
        if n % p == 0:
            cnt = 0
            while n % p == 0:
                n //= p
                cnt += 1
            if p % 4 == 3 and cnt % 2 == 1:
                return 0
        p += 1
    if n > 1:
        if n % 4 == 3:
            return 0
    return 1
