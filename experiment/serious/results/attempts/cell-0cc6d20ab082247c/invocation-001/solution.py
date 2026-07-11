def date_valid(d):
    if d <= 0:
        return 0

    day = d % 100
    month = (d // 100) % 100
    year = d // 10000

    if year < 1 or year > 9999 or month < 1 or month > 12 or day < 1:
        return 0

    month_lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if month == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0):
        max_day = 29
    else:
        max_day = month_lengths[month - 1]

    return 1 if day <= max_day else 0
