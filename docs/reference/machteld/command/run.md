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
- `-mem size` sets the per-process Job Object committed-memory limit. `0` (the
  default) means no limit. It is not a working-set/RSS cap or a combined tree
  budget. Sizes use the runtime binary-size grammar.
- `-cpu duration` sets the per-process cumulative user-mode CPU-time limit.
  Omitted or `0ms` means no limit; a bare `0` is not a duration. This is not
  elapsed time, a CPU percentage, or an aggregate tree limit.
- `-dir path` selects the working directory; the default is inherited.
- `-env dict` overlays environment names and values on the inherited
  environment. Names compare case-insensitively on Windows.
- `-arg0 word` changes only argument zero after executable resolution.
- `-stdin bytes` supplies the child's standard input and then closes it. A
  bytearray is written byte-for-byte; any other value is written as UTF-8.
  Without `-stdin`, captured mode connects standard input to `NUL`.
- `-onout script` and `-onerr script` stream complete lines to callbacks. The
  line (without newline or a trailing carriage return) is appended as one
  argument to the script prefix and evaluated at global scope. Callback-mode
  output must be valid UTF-8. Each line is limited to 16 MiB of incoming bytes,
  excluding LF but including an optional trailing CR. The limit is enforced
  during reading, including for a line that never ends. The final partial line
  at EOF is delivered once, with the same validation and limit.
- `-inherit` connects the child directly to the host's standard handles and
  disables captured output. It cannot be combined with callbacks or `-stdin`.

## Results

Returns a dict with `status`, `exit`, `pid`, `out`, `err`, and `truncated`.
`status` is `ok`, `error`, `timeout`, or `killed`; `exit` is the root process's
32-bit exit code. Captured `out` and `err` are bytearrays containing the first
1 MiB of each stream; `truncated` lists streams that exceeded that bound. A
stream delivered to a callback is not also retained in its result field; the
other stream is still captured unless it too has a callback. In inherited mode
both output fields are empty.

A deadline is represented by `status timeout`, not raised as a Tcl error. The
root can exit before a descendant, so `exit 0` and `status timeout` can coexist.

## Errors

Raised Machteld codes are `RUN badvalue`, `RUN launch`, `RUN notfound`,
`RUN limit`, `RUN oserror`, and `RUN usage`. An oversized callback line raises
`{MACHTELD RUN limit}` after terminating the supervised tree; the partial line
is not delivered. A callback failure is re-raised unchanged after
the supervised tree has been terminated. Tcl may also report wrong arity or
value-conversion errors.

## Lifetime and timeouts

The call blocks until the whole Job Object is empty, including descendants, or
until its lifetime deadline kills that tree. Capture drains concurrently to
avoid pipe deadlock. Callback mode pumps output on the calling thread; it does
not promise to service unrelated Tcl events. It alternates reads of at most
8192 bytes from each stream so a continuous stdout burst cannot prevent stderr
draining. Callback code itself must return promptly. For a responsive Tk window,
use `child start -channels` and bounded channel-event callbacks instead of `run`.
The deadline can terminate the tree while a callback is running, but it cannot
interrupt that Tcl callback or bound cleanup time.

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
I/O for streams whose total size is unbounded (individual callback lines still
have the 16 MiB limit). Use capture or `child -channels` for arbitrary binary
output or custom framing because callback lines require UTF-8. A callback may
retain its arguments itself; that application-owned memory is not bounded by
`run`. `manifest` exposes the capture, line and per-stream read limits.

Jobs own lifetime, not authority: the child retains the user's permissions.
`-dir` is not confinement and `-env` does not remove inherited credentials.
Memory/CPU caps apply separately to every process in the job; a descendant can
consume its own allowance. Limit-triggered exits are not reported as the
explicit lifetime-timeout status, and termination does not roll back work.

## See also

`machteld/command/child`, `machteld/command/scope`,
`machteld/command/detach`, `machteld/guide/execution-model`.
