def collatz_max(n):
    if n <= 0:
        return 0

    largest = n
    current = n

    while current != 1:
        if current % 2 == 0:
            current //= 2
        else:
            current = 3 * current + 1

        if current > largest:
            largest = current

    return largest
