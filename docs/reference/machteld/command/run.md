---
id: machteld/command/run
type: command
title: run
summary: Launch a supervised process tree, wait for it, and return bounded output and status.
commands: run
---

# run

`run` is the linear, supervised process launcher. The new process is born into
Machteld's root Job Object and its own kill-on-close job before user code runs.

## Synopsis

```tcl
run ?-timeout duration? ?-mem size? ?-cpu duration? ?-dir path? \
    ?-env dict? ?-arg0 word? ?-stdin bytes? ?-onout script? \
    ?-onerr script? ?-inherit? ?--? command ?arg ...?
```

Use `--` when `command` or one of its arguments could be read as an option.

## Arguments and options

- `command ?arg ...?` is the executable and its argument vector. A bare command
  is searched only in `PATH`; Machteld tries `.exe`, `.com`, `.bat`, and `.cmd`
  when it has no extension. The current directory is not searched implicitly.
- `-timeout duration` sets a lifetime deadline for the complete process tree.
  There is no default deadline. Durations require `ms`, `s`, `m`, or `h`.
- `-mem size` sets the per-process Job Object memory limit. `0` (the default)
  means no limit. Sizes use the runtime binary-size grammar.
- `-cpu duration` sets the per-process CPU-time limit. `0` (the default) means
  no limit; this is CPU time, not elapsed time.
- `-dir path` selects the working directory; the default is inherited.
- `-env dict` overlays environment names and values on the inherited
  environment. Names compare case-insensitively on Windows.
- `-arg0 word` changes only argument zero after executable resolution.
- `-stdin bytes` supplies the child's standard input and then closes it. Without
  `-stdin`, captured mode connects standard input to `NUL`.
- `-onout script` and `-onerr script` stream complete lines to callbacks. The
  line (without newline or a trailing carriage return) is appended as one
  argument to the script prefix and evaluated at global scope. Callback-mode
  output must be valid UTF-8.
- `-inherit` connects the child directly to the host's standard handles and
  disables captured output. It cannot be combined with callbacks or `-stdin`.

## Results

Returns a dict with `status`, `exit`, `pid`, `out`, `err`, and `truncated`.
`status` is `ok`, `error`, `timeout`, or `killed`; `exit` is the root process's
32-bit exit code. In captured mode `out` and `err` contain the first 1 MiB of
each stream and `truncated` lists streams that exceeded that bound. In inherited
mode both captured strings are empty.

A deadline is represented by `status timeout`, not raised as a Tcl error. The
root can exit before a descendant, so `exit 0` and `status timeout` can coexist.

## Errors

Raised Machteld codes are `RUN badvalue`, `RUN launch`, `RUN notfound`,
`RUN oserror`, and `RUN usage`. A callback failure is re-raised unchanged after
the supervised tree has been terminated. Tcl may also report wrong arity or
value-conversion errors.

## Lifetime and timeouts

The call blocks until the whole Job Object is empty, including descendants, or
until its lifetime deadline kills that tree. Capture drains concurrently to
avoid pipe deadlock. Callback mode pumps output on the calling thread; it does
not promise to service unrelated Tcl events.

## Examples

```tcl
set r [run -timeout 30s -dir C:/work -env {MODE test} -- tool.exe -q]
if {[dict get $r status] ne "ok"} {
    puts stderr [dict get $r err]
}

run -inherit -- git log --oneline
```

## Constraints

This is a Windows process launch, not shell evaluation: quoting and redirection
characters are ordinary arguments. Use `cmd.exe /c` explicitly when shell
syntax is intended. Capture is intentionally bounded; use callbacks or inherited
I/O for unbounded streams. Use capture or `child -channels` for arbitrary binary
output because callback lines require UTF-8.

## See also

`machteld/command/child`, `machteld/command/scope`,
`machteld/command/detach`, `machteld/guide/execution-model`.
