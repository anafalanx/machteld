---
id: machteld/command/wait
type: command
title: wait
summary: Wait for supervised child and filesystem-watch handles.
commands: wait
---

# wait

## Synopsis

```tcl
wait ?-any? token ?token ...?
```

## Arguments and options

Each `token` must be a live handle returned by `child start` or `watch start`.
Tokens must be unique and at most 64 may be supplied. With `-any`, the command
returns when one becomes ready. Without it, the command waits for all tokens.

## Results

Returns a list of ready tokens. In all-mode the list contains every supplied
token; in any-mode it contains tokens already ready at inspection time or the
one whose wait completed.

## Errors

Raised codes are `WAIT badvalue`, `WAIT nohandle`, `WAIT oserror`, and
`WAIT usage`. A stale, foreign, duplicated, or unsupported handle is rejected.

## Lifetime and timeouts

`wait` has no timeout option and does not consume or close a handle. Use
`child wait -timeout` to bound observation of one child, or arrange a separate
event source when multiplexing. A watch remains ready until `watch read`
consumes its queued state; a completed child remains ready.

## Examples

```tcl
set build [child start -- build.exe]
set changes [watch start C:/src -recursive]
set ready [wait -any $build $changes]
if {$changes in $ready} { set events [watch read $changes] }
```

## Constraints

The command blocks the calling thread and does not promise to pump Tcl's event
loop. It multiplexes only Machteld child and watch handles, not arbitrary Tcl
channels or Windows handles.

## See also

`machteld/command/child#wait`, `machteld/command/watch`,
`machteld/guide/execution-model`.
