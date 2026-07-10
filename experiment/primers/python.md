# Python — reference

Write an ordinary Python 3 solution.

## Defining your solution

Define a function with the **exact name** the task gives, taking the stated
arguments and returning the result:

- one output → return that value;
- multiple outputs → return a tuple/list of values in order;
- a task-designated failure → raise an exception.

```python
def square(n):
    return n * n
```

The standard library is available. The function must be importable from the
solution file: do not prompt, read stdin, or perform work at import time.

## Solving a task

1. Write the function with the exact name and argument count from `task.md`.
2. Run the provided `check.cmd`. It evaluates visible examples
   and shows ordinary Python tracebacks when an error occurs.
3. Iterate until it passes, then leave the final function in `solution.py`.
