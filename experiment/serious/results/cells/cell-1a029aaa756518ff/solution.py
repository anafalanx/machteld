def luhn_valid(n):
    if n < 0:
        return 0

    total = 0
    position = 1

    while n > 0:
        digit = n % 10
        n //= 10

        if position % 2 == 0:
            digit *= 2
            if digit > 9:
                digit -= 9

        total += digit
        position += 1

    return 1 if total % 10 == 0 else 0
