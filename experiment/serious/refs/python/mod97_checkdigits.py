def mod97_checkdigits(n):
    if n < 0 or n > 10**18 - 1:
        return -1
    r = (n % 97) * 100 % 97
    return (1 - r) % 97
