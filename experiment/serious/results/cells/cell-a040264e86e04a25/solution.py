def regmachine(prog, k):
    if k < 0:
        return 0

    acc = 0
    pc = 0
    steps = 0

    while steps < k and pc < 16:
        opcode = (prog >> (4 * pc)) & 0xF

        if opcode == 0:
            break

        steps += 1

        if opcode == 1:
            acc += 1
        elif opcode == 2:
            acc -= 1
        elif opcode == 3:
            acc *= 2
        elif opcode == 4:
            acc = -acc
        elif opcode == 5:
            acc = acc // 2 if acc >= 0 else -((-acc) // 2)
        elif opcode == 6:
            acc += 3
        elif opcode == 7:
            acc -= 5
        elif opcode == 8:
            pc += 2 if acc == 0 else 1
            continue
        elif opcode == 9:
            pc += 2 if acc != 0 else 1
            continue
        elif opcode == 10:
            acc *= 3
        elif opcode == 11:
            acc = acc % 2 if acc >= 0 else -((-acc) % 2)
        elif opcode == 12:
            acc = abs(acc)
        elif opcode == 13:
            acc = 0
        elif opcode == 14:
            acc += 2
        else:  # opcode == 15
            acc -= 2

        pc += 1

    return acc
