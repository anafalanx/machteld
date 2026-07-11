# machteld/Tcl reference

Write an ordinary Tcl 9 script executed by machteld. Tcl commands consist of
words separated by whitespace. `$name` substitutes a variable, `[command ...]`
runs a nested command, and braces group a body or expression without immediate
substitution.

Define the requested global procedure with `proc`, and return a four-element
Tcl list:

```tcl
proc example {value} {
    return [list ok 0 $value ""]
}
```

Use `if` with a braced expression and `eq` for string comparison:

```tcl
if {$status eq "ok"} {
    # ...
}
```

## Running a process

machteld preloads the `run` command. Give the executable and each argument as
separate Tcl words. `--` ends machteld option parsing, so no command shell
interprets spaces, quotes, backslashes, or shell metacharacters:

```tcl
set result [run -timeout 200ms -- $program $first_argument $second_argument]
```

The timeout unit is mandatory. `run` blocks until the process has exited or
has been terminated and reaped. It returns a Tcl dictionary with these fields:

```text
exit status out err pid truncated
```

Read a field with `dict get`, for example:

```tcl
set status [dict get $result status]
set stdout [dict get $result out]
```

`status` is `ok` for exit zero, `error` for a completed nonzero exit, and
`timeout` when the deadline expires. A nonzero exit and a timeout are returned
normally; they are not Tcl errors. `out` and `err` are the separately captured
UTF-8 strings. The native termination exit value on timeout is an
implementation detail, so apply the task's required `-1` normalization.

The helper is deliberately supplied as an opaque executable. Always run it;
do not branch on the mode to manufacture an answer. Do no work while the
solution file is being sourced.
