def run(cmds):
    store = {}
    txns = []  # stack of undo logs; each log is a list of (key, had, old)
    out = []

    def record(key):
        if not txns:
            return
        if key in store:
            txns[-1].append((key, True, store[key]))
        else:
            txns[-1].append((key, False, None))

    def parse_int(tok):
        # base-10 integer numeral: optional +/- sign then one or more ASCII
        # decimal digits, and NOTHING else -- so embedded whitespace, floats,
        # hex, and junk are all rejected. The value must fit signed 64 bits
        # ([-2**63, 2**63-1]); out-of-range magnitudes are malformed. This keeps
        # the parse identical to the els/Lua int64 reference.
        body = tok[1:] if tok[:1] in "+-" else tok
        if body == "" or any(c not in "0123456789" for c in body):
            raise ValueError("not an integer: " + tok)
        v = int(tok)
        if v < -(2 ** 63) or v > 2 ** 63 - 1:
            raise ValueError("integer out of range: " + tok)
        return v

    for cmd in cmds:
        # Split on the SPACE character only, dropping empty tokens (collapsing
        # runs of spaces and trimming) -- mirrors the els tokenizer exactly.
        toks = [t for t in cmd.split(" ") if t != ""]
        if not toks:
            raise ValueError("empty command")
        word = toks[0]
        if word == "SET":
            if len(toks) != 3:
                raise ValueError("SET needs 2 args")
            v = parse_int(toks[2])
            record(toks[1])
            store[toks[1]] = v
        elif word == "GET":
            if len(toks) != 2:
                raise ValueError("GET needs 1 arg")
            val = store.get(toks[1])
            out.append("NULL" if val is None else str(val))
        elif word == "UNSET":
            if len(toks) != 2:
                raise ValueError("UNSET needs 1 arg")
            record(toks[1])
            store.pop(toks[1], None)
        elif word == "COUNT":
            if len(toks) != 2:
                raise ValueError("COUNT needs 1 arg")
            target = parse_int(toks[1])
            out.append(str(sum(1 for x in store.values() if x == target)))
        elif word == "BEGIN":
            if len(toks) != 1:
                raise ValueError("BEGIN takes no args")
            txns.append([])
        elif word == "ROLLBACK":
            if len(toks) != 1:
                raise ValueError("ROLLBACK takes no args")
            if not txns:
                out.append("NO TRANSACTION")
            else:
                log = txns.pop()
                for key, had, old in reversed(log):
                    if had:
                        store[key] = old
                    else:
                        store.pop(key, None)
        elif word == "COMMIT":
            if len(toks) != 1:
                raise ValueError("COMMIT takes no args")
            txns.clear()
        else:
            raise ValueError("unknown command: " + word)

    return "\n".join(out)
