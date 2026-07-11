def iban_check(n):
    r = 0
    pw = 1
    m = n
    while m > 0:
        d = m % 10
        r = (r + d * pw) % 97
        pw = (pw * 10) % 97
        m //= 10
    return 98 - (r * 100) % 97
