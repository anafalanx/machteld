def mod97_checkdigits(n):
    if n < 0 or n > 999_999_999_999_999_999:
        return -1

    remainder = ((n % 97) * 100) % 97
    return (1 - remainder) % 97
