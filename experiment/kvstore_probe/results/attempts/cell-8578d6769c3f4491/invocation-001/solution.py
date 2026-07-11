import re


_INTEGER = re.compile(r"[+-]?[0-9]+")
_MIN_INT64 = -(2 ** 63)
_MAX_INT64 = 2 ** 63 - 1


def _value(token):
    if _INTEGER.fullmatch(token) is None:
        raise ValueError("invalid integer")
    value = int(token, 10)
    if value < _MIN_INT64 or value > _MAX_INT64:
        raise ValueError("integer out of range")
    return value


def run(cmds):
    store = {}
    counts = {}
    transactions = []
    output = []

    def set_key(key, new_value):
        if key in store:
            old_value = store[key]
            counts[old_value] -= 1
            if counts[old_value] == 0:
                del counts[old_value]

        if new_value is None:
            store.pop(key, None)
        else:
            store[key] = new_value
            counts[new_value] = counts.get(new_value, 0) + 1

    for command in cmds:
        if not isinstance(command, str):
            raise ValueError("command must be a string")
        fields = [field for field in command.split(" ") if field != ""]
        if not fields:
            raise ValueError("empty command")

        word = fields[0]

        if word == "SET":
            if len(fields) != 3:
                raise ValueError("SET expects two arguments")
            set_key(fields[1], _value(fields[2]))
        elif word == "GET":
            if len(fields) != 2:
                raise ValueError("GET expects one argument")
            output.append(str(store[fields[1]]) if fields[1] in store else "NULL")
        elif word == "UNSET":
            if len(fields) != 2:
                raise ValueError("UNSET expects one argument")
            set_key(fields[1], None)
        elif word == "COUNT":
            if len(fields) != 2:
                raise ValueError("COUNT expects one argument")
            output.append(str(counts.get(_value(fields[1]), 0)))
        elif word == "BEGIN":
            if len(fields) != 1:
                raise ValueError("BEGIN expects no arguments")
            transactions.append((store.copy(), counts.copy()))
        elif word == "ROLLBACK":
            if len(fields) != 1:
                raise ValueError("ROLLBACK expects no arguments")
            if transactions:
                store, counts = transactions.pop()
            else:
                output.append("NO TRANSACTION")
        elif word == "COMMIT":
            if len(fields) != 1:
                raise ValueError("COMMIT expects no arguments")
            transactions.clear()
        else:
            raise ValueError("unknown command")

    return "\n".join(output)
