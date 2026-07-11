def rpn_eval(prog, length):
    """Evaluate up to eight LSB-first packed RPN tokens."""
    if length < 0:
        length = 0
    elif length > 8:
        length = 8

    stack = []

    for i in range(length):
        token = (prog >> (4 * i)) & 0xF

        if token <= 9:
            if len(stack) < 4:
                stack.append(token)
            continue

        if token >= 14 or len(stack) < 2:
            continue

        b = stack.pop()
        a = stack.pop()

        if token == 10:
            value = a + b
        elif token == 11:
            value = a - b
        elif token == 12:
            value = a * b
        else:
            if b == 0:
                value = 0
            else:
                quotient = abs(a) // abs(b)
                value = -quotient if (a < 0) != (b < 0) else quotient

        stack.append(value)

    return stack[-1] if stack else 0
