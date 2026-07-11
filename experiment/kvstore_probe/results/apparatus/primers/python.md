# Python scripting reference

Write an ordinary Python 3 module. Define the exact function named in
`task.md`; do not read stdin, print the answer, or do task work while the module
is imported. The checker calls the function directly and evaluates every
example in a fresh process.

```python
def summarize(items):
    return ",".join(items)
```

## Control flow, lists, and strings

```python
out = []
for item in items:
    if item != "":
        out.append(item)
first = out[0]
n = len(out)
text = "\n".join(out)
```

Strings compare with `==` and `!=`. `for`, `while`, `break`, and `continue`
are available. Useful list operations include list literals, `append`, indexed
access, `len`, slice replacement, `reversed`, and tuple unpacking.

Strings are exact values. `len(text)`, `text[index]`, and slices inspect them.
To split on the ASCII space character only and drop empty fields (without
treating tabs or newlines as separators):

```python
fields = [field for field in text.split(" ") if field != ""]
```

## Dictionaries

A Python dictionary maps keys to values:

```python
mapping = {}
mapping[key] = value
if key in mapping:
    value = mapping[key]
    del mapping[key]
for key, value in mapping.items():
    # inspect each pair
    pass
```

Lists can contain other lists or dictionaries. This is often convenient for a
stack: `stack.append(value)`, `stack[-1]`, and `stack.pop()` push, read, and
pop.

## Validation and errors

The standard-library `re.fullmatch` function proves that a pattern covers the
entire string:

```python
import re

whole = re.fullmatch(r"[+-]?[0-9]+", token) is not None
```

Raise an error with `raise ValueError("message")`. An uncaught exception from
the requested function is how a fallible case is reported to the checker.

Python integers have arbitrary precision. If a task specifies a signed-64-bit
range, validate the result explicitly against `-(2 ** 63)` and
`2 ** 63 - 1`; do not rely on overflow. `ord(character)` returns a character's
integer code when manual ASCII processing is useful.

Read all of `task.md`, edit only `solution.py`, and use `check.cmd` for the
visible examples. Stop after it passes or after leaving your best attempt.
