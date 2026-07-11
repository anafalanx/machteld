def bracket_balanced(n, length):
    if length < 0:
        return 0
    if length == 0:
        return 1
    depth = 0
    for i in range(length):
        bit = (n >> i) & 1
        depth += 1 if bit == 0 else -1
        if depth < 0:
            return 0
    return 1 if depth == 0 else 0
