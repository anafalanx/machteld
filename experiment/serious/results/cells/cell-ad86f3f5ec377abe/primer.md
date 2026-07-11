# Python — serious-task reference

Write an ordinary Python 3 module. Every task in this corpus takes integers and
returns one integer. Use the exact function name shown in `task.md` and accept
the stated number of positional arguments.

## Submission contract

Define the requested function in `solution.py`. Helper functions are allowed.
Do not prompt, read stdin, print a result, or run task work while the module is
being imported. The checker imports the file and calls the function directly.

```python
def square(n):
    return n * n
```

Run `check.cmd` to evaluate the visible examples. Each case is evaluated in a
fresh Python process, so do not rely on state left by another case.

## Python syntax

Assignments create local variables. Indentation delimits decisions and loops:

```python
x = 4
y = x + 1

if x < 0:
    x = -x
elif x == 0:
    x = 1

i = 0
while i < 10:
    i += 1

for i in range(10):
    pass
```

`break` and `continue` work inside loops. Return the requested integer with
`return value`.

## Integer and remainder conventions

Python integers grow beyond 64 bits. Preserve the task's stated signed-64-bit
input interpretation, but do not clip intermediate values unless the task
explicitly requires a fixed-width bit pattern.

Arithmetic and comparison operators include `+ - * // %`, `< <= == != >= >`,
`and or not`, and the bit operators `& | ^ ~ << >>`. `//` is integer floor
division and `%` has the divisor's sign. `>>` is arithmetic (sign-extending) on
negative values.

Some tasks explicitly require division truncated toward zero or a remainder
with the dividend's sign. These general helpers implement that contract without
using floating point:

```python
def tdiv(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def trem(a, b):
    q = tdiv(a, b)
    return a - q * b
```

Normalize a remainder to `[0,m)` for positive `m` with:

```python
def modnorm(a, m):
    return ((a % m) + m) % m
```

For a logical right shift of a raw 64-bit two's-complement pattern, mask before
the arithmetic shift:

```python
MASK64 = (1 << 64) - 1


def u64(x):
    return x & MASK64


def lsr64(x, n):
    return (x & MASK64) >> n
```

Use the task's narrower mask when it specifies a width below 64 bits.

## Lists and common operations

Build a list with brackets, append with `.append`, and index nested lists one
level at a time:

```python
values = [3, 5, 7]
values.append(9)
first = values[0]
cell = table[row][column]

for value in values:
    pass
```

Useful built-ins include `abs`, `min`, and `max`. The Python standard library is
available, but the solution must remain importable without installation or
network access.

## Solving a task

1. Read all of `task.md`, including its boundary and sign conventions.
2. Define the exact requested function in `solution.py`.
3. Run `check.cmd` and repair any visible mismatch.
4. Stop after it passes, leaving the final solution file in place.

