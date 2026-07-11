def date_valid(d):
    if d <= 0:
        return 0
    day = d % 100
    md = d // 100
    month = md % 100
    year = md // 100
    if year < 1 or year > 9999:
        return 0
    if month < 1 or month > 12:
        return 0
    if day < 1:
        return 0
    dim = [31,28,31,30,31,30,31,31,30,31,30,31][month - 1]
    if month == 2 and ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0):
        dim = 29
    if day > dim:
        return 0
    return 1
