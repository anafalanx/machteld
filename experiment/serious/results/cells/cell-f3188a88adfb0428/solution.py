def iban_check(n):
    return 98 - ((n % 97) * 100 % 97)
