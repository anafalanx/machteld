def collatz_max(n):
    if n <= 0:
        return 0

    largest = n
    while n != 1:
        if n % 2 == 0:
            n //= 2
        else:
            n = 3 * n + 1
        if n > largest:
            largest = n

    return largest
