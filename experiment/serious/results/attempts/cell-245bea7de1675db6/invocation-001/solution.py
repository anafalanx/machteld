def upca_check(body):
    if body < 0 or body > 99999999999:
        return -1

    total = 0
    weight = 3
    for _ in range(11):
        total += (body % 10) * weight
        body //= 10
        weight = 4 - weight

    return (-total) % 10
