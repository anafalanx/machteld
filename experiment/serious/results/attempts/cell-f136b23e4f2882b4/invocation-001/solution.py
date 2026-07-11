def isbn13_valid(n):
    if n < 0 or n > 9_999_999_999_999:
        return 0

    weighted_sum = 0
    remaining = n
    for position_from_right in range(13):
        digit = remaining % 10
        weight = 1 if position_from_right % 2 == 0 else 3
        weighted_sum += weight * digit
        remaining //= 10

    return 1 if weighted_sum % 10 == 0 else 0
