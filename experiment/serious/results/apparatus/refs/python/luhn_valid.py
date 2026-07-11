def luhn_valid(n):
    if n < 0:
        return 0
    s = 0
    pos = 0
    while True:
        d = n % 10
        if pos % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        s += d
        n //= 10
        pos += 1
        if n == 0:
            break
    return 1 if s % 10 == 0 else 0
