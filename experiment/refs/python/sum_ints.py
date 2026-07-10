import re


DECIMAL = re.compile(r"[+-]?[0-9]+\Z", re.ASCII)


def sum_ints(s):
    total = 0
    for tok in s.split():
        if DECIMAL.fullmatch(tok):
            total += int(tok)
    return total
