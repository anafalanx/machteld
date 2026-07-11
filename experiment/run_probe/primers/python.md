# Python reference

Write an ordinary Python 3 module. Define the requested function with the
exact name and arguments, return a four-element list, and perform no work when
the module is imported.

## Running a process

The standard-library `subprocess.run` function accepts an argument sequence.
With `shell=False`, each sequence element is one process argument and no
command shell interprets spaces, quotes, backslashes, or shell
metacharacters:

```python
import subprocess

completed = subprocess.run(
    [program, first_argument, second_argument],
    shell=False,
    capture_output=True,
    text=True,
    encoding="utf-8",
    errors="strict",
    timeout=0.2,
    check=False,
)
```

For a completed process, `completed.returncode`, `completed.stdout`, and
`completed.stderr` contain the exit code and the two captured text streams.
Because `check=False`, a nonzero exit is returned normally.

If the deadline expires, `subprocess.run` kills and waits for the directly
launched process, then raises `subprocess.TimeoutExpired`. Catch that exception
and apply the task's required timeout result. The helper emits no output in its
`hang` mode, so the required timeout streams are empty.

The helper is deliberately supplied as an opaque executable. Always run it;
do not branch on the mode to manufacture an answer.
