def isbn13_valid(n):
    if n < 0 or n > 9999999999999:
        return 0

    total = 0
    for position in range(13):
        digit = n % 10
        total += digit if position % 2 == 0 else 3 * digit
        n //= 10

    return 1 if total % 10 == 0 else 0
