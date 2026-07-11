def regmachine(prog, k):
    NIBBLES = 16
    if k < 0:
        return 0
    acc = 0
    pc = 0
    steps = 0
    while steps < k and pc < NIBBLES:
        op = (prog >> (4 * pc)) & 0xF
        if op == 0:
            break
        elif op == 1: acc += 1
        elif op == 2: acc -= 1
        elif op == 3: acc *= 2
        elif op == 4: acc = -acc
        elif op == 5: acc = int(acc / 2) if acc < 0 else acc // 2
        elif op == 6: acc += 3
        elif op == 7: acc -= 5
        elif op == 8:
            if acc == 0:
                pc += 2; steps += 1; continue
        elif op == 9:
            if acc != 0:
                pc += 2; steps += 1; continue
        elif op == 10: acc *= 3
        elif op == 11: acc = abs(acc) % 2 * (1 if acc >= 0 else -1)
        elif op == 12: acc = abs(acc)
        elif op == 13: acc = 0
        elif op == 14: acc += 2
        elif op == 15: acc -= 2
        pc += 1
        steps += 1
    return acc
