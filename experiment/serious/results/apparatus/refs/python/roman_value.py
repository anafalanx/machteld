def roman_value(n):
    if n <= 0:
        return -1
    sym = {1:1, 2:5, 3:10, 4:50, 5:100, 6:500, 7:1000}
    codes = []
    m = n
    while m > 0:
        codes.append(m % 10)
        m //= 10
    codes.reverse()
    for c in codes:
        if c < 1 or c > 7:
            return -1
    total = 0
    prev = 0
    for c in reversed(codes):
        v = sym[c]
        if v < prev:
            total -= v
        else:
            total += v
            prev = v
    if total < 1 or total > 3999:
        return -1
    vals = [(1000,[7]),(900,[5,7]),(500,[6]),(400,[5,6]),(100,[5]),(90,[3,5]),(50,[4]),(40,[3,4]),(10,[3]),(9,[1,3]),(5,[2]),(4,[1,2]),(1,[1])]
    out = []
    val = total
    for v, c in vals:
        while val >= v:
            out.extend(c)
            val -= v
    pack = 0
    for c in out:
        pack = pack * 10 + c
    return total if pack == n else -1
