def damm_valid(n):
    if n < 0:
        return 0

    table = (
        "0317598642",
        "7092154863",
        "4206871359",
        "1750983426",
        "6123045978",
        "3674209581",
        "5869720134",
        "8945362017",
        "9438617205",
        "2581436790",
    )

    interim = 0
    for digit in str(n):
        interim = ord(table[interim][ord(digit) - ord("0")]) - ord("0")

    return 1 if interim == 0 else 0
