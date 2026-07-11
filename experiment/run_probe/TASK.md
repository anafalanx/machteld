# Task: run_probe

Define a function named **`run_probe`** taking three arguments:

1. `helper`: an absolute path to the supplied native helper executable;
2. `mode`: one of `ok`, `fail`, or `hang`;
3. `payload`: an arbitrary Unicode string without a NUL character.

For the machteld arm, define:

```tcl
proc run_probe {helper mode payload} { ... }
```

For the Python arm, define:

```python
def run_probe(helper, mode, payload):
    ...
```

Launch the helper directly with exactly two arguments, `mode` and `payload`.
Do not invoke a command shell. Apply a fixed timeout of **200 milliseconds** and
capture stdout and stderr separately as UTF-8 text.

Return exactly four values, in this order:

```text
[status, exit, out, err]
```

- A completed exit code of zero maps to status `ok`.
- A completed nonzero exit maps to status `error`, preserving the exact exit
  code.
- A timeout maps to status `timeout`, exit `-1`, and empty `out` and `err`.
- Do not raise an error merely because the helper exits nonzero or times out.
- On timeout, do not return until the directly launched helper is dead and
  reaped.

Every call, including `hang`, must really launch the helper. Do not infer or
manufacture a result from the mode. The checker independently verifies timeout
cleanup.

The helper's completed behavior is:

- `ok PAYLOAD`: exit `0`; stdout is exactly `PAYLOAD`; stderr is exactly
  `E:PAYLOAD`.
- `fail PAYLOAD`: exit `7`; streams are the same as for `ok`.
- `hang PAYLOAD`: emit nothing and sleep well beyond the deadline.

The helper adds no newline to either stream.

Visible examples:

```text
ok,   "hello world"
  -> ["ok", 0, "hello world", "E:hello world"]

fail, "a\"b\\c & d"
  -> ["error", 7, "a\"b\\c & d", "E:a\"b\\c & d"]

hang, "ignored"
  -> ["timeout", -1, "", ""]
```

Write the requested function (plus any necessary import) in
`{{SOLUTION_FILE}}`. It must be safe to source or import without running the
helper at load time. Use `check.cmd` for visible feedback; hidden cases are
used after submission.
