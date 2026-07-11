def rpn_eval(prog, length):
    """Evaluate up to eight LSB-first packed RPN tokens."""
    token_count = min(max(length, 0), 8)
    stack = []

    for i in range(token_count):
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
            result = a + b
        elif token == 11:
            result = a - b
        elif token == 12:
            result = a * b
        else:
            if b == 0:
                result = 0
            else:
                quotient = abs(a) // abs(b)
                result = -quotient if (a < 0) != (b < 0) else quotient

        stack.append(result)

    return stack[-1] if stack else 0
