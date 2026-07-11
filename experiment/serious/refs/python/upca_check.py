def upca_check(body11):
    if body11 < 0 or body11 > 99999999999:
        return -1
    s = 0
    cnt = 0
    while True:
        d = body11 % 10
        w = 3 if cnt % 2 == 0 else 1
        s += d * w
        cnt += 1
        body11 //= 10
        if body11 == 0:
            break
    return (10 - (s % 10)) % 10
