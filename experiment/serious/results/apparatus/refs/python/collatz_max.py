def collatz_max(n):
    if n <= 0:
        return 0
    best = n
    while n != 1:
        n = n // 2 if n % 2 == 0 else 3 * n + 1
        if n > best:
            best = n
    return best
