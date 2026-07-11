def bracket_balanced(n, length):
    if length < 0:
        return 0

    depth = 0
    for i in range(length):
        if (n >> i) & 1:
            depth -= 1
            if depth < 0:
                return 0
        else:
            depth += 1

    return 1 if depth == 0 else 0
