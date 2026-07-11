def isbn13_valid(n):
    if n < 0 or n > 9_999_999_999_999:
        return 0

    total = 0
    weight = 1
    for _ in range(13):
        total += (n % 10) * weight
        n //= 10
        weight = 4 - weight

    return 1 if total % 10 == 0 else 0
