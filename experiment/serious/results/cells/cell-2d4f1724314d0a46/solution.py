def roman_value(n):
    if n <= 0:
        return -1

    symbol_values = (0, 1, 5, 10, 50, 100, 500, 1000)
    remaining = n
    maximum = 0
    value = 0

    while remaining:
        code = remaining % 10
        remaining //= 10
        if code < 1 or code > 7:
            return -1

        symbol = symbol_values[code]
        if symbol < maximum:
            value -= symbol
        else:
            value += symbol
            maximum = symbol

    if value < 1 or value > 3999:
        return -1

    canonical_parts = (
        (1000, (7,)),
        (900, (5, 7)),
        (500, (6,)),
        (400, (5, 6)),
        (100, (5,)),
        (90, (3, 5)),
        (50, (4,)),
        (40, (3, 4)),
        (10, (3,)),
        (9, (1, 3)),
        (5, (2,)),
        (4, (1, 2)),
        (1, (1,)),
    )

    packed = 0
    rest = value
    for amount, codes in canonical_parts:
        while rest >= amount:
            rest -= amount
            for code in codes:
                packed = packed * 10 + code

    return value if packed == n else -1
