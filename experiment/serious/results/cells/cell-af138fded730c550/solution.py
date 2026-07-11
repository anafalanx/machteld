def luhn_valid(n):
    if n < 0:
        return 0

    total = 0
    double_digit = False

    while n > 0:
        digit = n % 10
        n //= 10

        if double_digit:
            digit *= 2
            if digit > 9:
                digit -= 9

        total += digit
        double_digit = not double_digit

    return 1 if total % 10 == 0 else 0
