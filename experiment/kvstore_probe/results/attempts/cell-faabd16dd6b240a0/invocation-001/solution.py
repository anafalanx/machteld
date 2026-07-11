import re


_INTEGER = re.compile(r"[+-]?[0-9]+")
_MIN_VALUE = -(2 ** 63)
_MAX_VALUE = 2 ** 63 - 1
_MISSING = object()


def _parse_value(token):
    if _INTEGER.fullmatch(token) is None:
        raise ValueError("malformed integer")

    value = int(token, 10)
    if value < _MIN_VALUE or value > _MAX_VALUE:
        raise ValueError("integer out of range")
    return value


def run(cmds):
    store = {}
    value_counts = {}
    transactions = []
    output = []

    def change_count(value, amount):
        new_count = value_counts.get(value, 0) + amount
        if new_count:
            value_counts[value] = new_count
        elif value in value_counts:
            del value_counts[value]

    def remember(key):
        if transactions and key not in transactions[-1]:
            transactions[-1][key] = store.get(key, _MISSING)

    def set_key(key, value):
        remember(key)
        if key in store:
            old_value = store[key]
            if old_value == value:
                return
            change_count(old_value, -1)
        store[key] = value
        change_count(value, 1)

    def unset_key(key):
        remember(key)
        if key in store:
            change_count(store[key], -1)
            del store[key]

    for command in cmds:
        if not isinstance(command, str):
            raise ValueError("command is not a string")

        parts = [part for part in command.split(" ") if part != ""]
        if not parts:
            raise ValueError("empty command")

        name = parts[0]

        if name == "SET":
            if len(parts) != 3:
                raise ValueError("malformed SET")
            set_key(parts[1], _parse_value(parts[2]))

        elif name == "GET":
            if len(parts) != 2:
                raise ValueError("malformed GET")
            if parts[1] in store:
                output.append(str(store[parts[1]]))
            else:
                output.append("NULL")

        elif name == "UNSET":
            if len(parts) != 2:
                raise ValueError("malformed UNSET")
            unset_key(parts[1])

        elif name == "COUNT":
            if len(parts) != 2:
                raise ValueError("malformed COUNT")
            value = _parse_value(parts[1])
            output.append(str(value_counts.get(value, 0)))

        elif name == "BEGIN":
            if len(parts) != 1:
                raise ValueError("malformed BEGIN")
            transactions.append({})

        elif name == "ROLLBACK":
            if len(parts) != 1:
                raise ValueError("malformed ROLLBACK")
            if not transactions:
                output.append("NO TRANSACTION")
                continue

            undo = transactions.pop()
            for key, old_value in undo.items():
                if key in store:
                    change_count(store[key], -1)
                if old_value is _MISSING:
                    store.pop(key, None)
                else:
                    store[key] = old_value
                    change_count(old_value, 1)

        elif name == "COMMIT":
            if len(parts) != 1:
                raise ValueError("malformed COMMIT")
            transactions.clear()

        else:
            raise ValueError("unknown command")

    return "\n".join(output)
