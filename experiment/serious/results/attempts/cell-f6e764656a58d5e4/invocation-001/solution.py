def isbn10_valid(body, check):
    if body < 0 or body > 999999999:
        return 0
    if check < 0 or check > 10:
        return 0

    total = check
    for weight in range(2, 11):
        digit = body % 10
        total += weight * digit
        body //= 10

    return 1 if total % 11 == 0 else 0
