def roman_value(n):
    if n <= 0:
        return -1

    symbol_values = (0, 1, 5, 10, 50, 100, 500, 1000)
    remaining = n
    maximum_to_right = 0
    value = 0

    while remaining:
        digit = remaining % 10
        remaining //= 10
        if digit < 1 or digit > 7:
            return -1

        symbol_value = symbol_values[digit]
        if symbol_value < maximum_to_right:
            value -= symbol_value
        else:
            value += symbol_value
            maximum_to_right = symbol_value

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

    canonical_pack = 0
    remainder = value
    for part_value, codes in canonical_parts:
        while remainder >= part_value:
            remainder -= part_value
            for code in codes:
                canonical_pack = canonical_pack * 10 + code

    return value if canonical_pack == n else -1
