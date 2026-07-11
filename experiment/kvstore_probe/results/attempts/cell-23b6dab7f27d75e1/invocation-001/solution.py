import re


_INTEGER = re.compile(r"[+-]?[0-9]+")
_MAX_POSITIVE = "9223372036854775807"
_MAX_NEGATIVE_MAGNITUDE = "9223372036854775808"


def _parse_value(token):
    if _INTEGER.fullmatch(token) is None:
        raise ValueError("invalid integer")

    negative = token[0] == "-"
    if token[0] == "+" or negative:
        digits = token[1:]
    else:
        digits = token

    significant = digits.lstrip("0") or "0"
    limit = _MAX_NEGATIVE_MAGNITUDE if negative else _MAX_POSITIVE
    if len(significant) > len(limit) or (
        len(significant) == len(limit) and significant > limit
    ):
        raise ValueError("integer out of range")

    value = int(significant)
    return -value if negative else value


def run(cmds):
    store = {}
    counts = {}
    transactions = []
    outputs = []
    missing = object()

    def remember(key):
        if transactions and key not in transactions[-1]:
            transactions[-1][key] = store.get(key, missing)

    def replace(key, value):
        old = store.get(key, missing)
        if old is not missing:
            remaining = counts[old] - 1
            if remaining:
                counts[old] = remaining
            else:
                del counts[old]

        if value is missing:
            store.pop(key, None)
        else:
            store[key] = value
            counts[value] = counts.get(value, 0) + 1

    for command in cmds:
        tokens = [token for token in command.split(" ") if token != ""]
        if not tokens:
            raise ValueError("empty command")

        name = tokens[0]

        if name == "SET":
            if len(tokens) != 3:
                raise ValueError("wrong number of arguments")
            key = tokens[1]
            value = _parse_value(tokens[2])
            remember(key)
            replace(key, value)

        elif name == "GET":
            if len(tokens) != 2:
                raise ValueError("wrong number of arguments")
            value = store.get(tokens[1], missing)
            outputs.append("NULL" if value is missing else str(value))

        elif name == "UNSET":
            if len(tokens) != 2:
                raise ValueError("wrong number of arguments")
            key = tokens[1]
            remember(key)
            replace(key, missing)

        elif name == "COUNT":
            if len(tokens) != 2:
                raise ValueError("wrong number of arguments")
            value = _parse_value(tokens[1])
            outputs.append(str(counts.get(value, 0)))

        elif name == "BEGIN":
            if len(tokens) != 1:
                raise ValueError("wrong number of arguments")
            transactions.append({})

        elif name == "ROLLBACK":
            if len(tokens) != 1:
                raise ValueError("wrong number of arguments")
            if not transactions:
                outputs.append("NO TRANSACTION")
            else:
                changes = transactions.pop()
                for key, old_value in changes.items():
                    replace(key, old_value)

        elif name == "COMMIT":
            if len(tokens) != 1:
                raise ValueError("wrong number of arguments")
            transactions.clear()

        else:
            raise ValueError("unknown command")

    return "\n".join(outputs)
