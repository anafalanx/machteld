def rpn_eval(prog, length):
    MAXLEN = 8
    if length < 0:
        length = 0
    if length > MAXLEN:
        length = MAXLEN
    def tdiv(a, b):
        if b == 0:
            return 0
        q = abs(a) // abs(b)
        return -q if (a < 0) != (b < 0) else q
    st = []
    for i in range(length):
        tok = (prog >> (4 * i)) & 0xF
        if tok <= 9:
            if len(st) < 4:
                st.append(tok)
        elif tok in (10, 11, 12, 13):
            if len(st) >= 2:
                b = st.pop(); a = st.pop()
                if tok == 10: r = a + b
                elif tok == 11: r = a - b
                elif tok == 12: r = a * b
                else: r = tdiv(a, b)
                st.append(r)
    return st[-1] if st else 0
