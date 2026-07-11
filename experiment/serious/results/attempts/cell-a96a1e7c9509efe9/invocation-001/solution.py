def upca_check(body):
    if body < 0 or body > 99999999999:
        return -1

    total = 0
    for position_from_right in range(11):
        digit = body % 10
        body //= 10
        weight = 3 if position_from_right % 2 == 0 else 1
        total += weight * digit

    return (10 - total % 10) % 10
