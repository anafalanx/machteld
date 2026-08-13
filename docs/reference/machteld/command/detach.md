---
id: machteld/command/detach
type: command
title: detach
summary: Launch a process outside all Windows jobs and return its PID.
commands: detach
---

# detach

## Synopsis

```tcl
detach ?-dir path? ?-env dict? ?-arg0 word? ?--? command ?arg ...?
```

## Arguments and options

`command` resolution, `-dir`, `-env`, `-arg0`, and `--` have the same meanings
as for `run`. The child's standard streams are connected to `NUL`. There are no
capture, callback, resource-limit, or deadline options.

## Results

Returns the new process ID after the launch has been verified to be outside
every Windows Job Object.

## Errors

Raised codes are `DETACH badvalue`, `DETACH launch`, `DETACH notfound`,
`DETACH oserror`, and `DETACH usage`. `DETACH launch` includes an enclosing
Windows policy that forbids strict breakaway.

## Lifetime and timeouts

Machteld relinquishes its process handle immediately after successful launch.
The detached process and its descendants can outlive the host. There is no
timeout and no later Machteld handle with which to observe or terminate it.

## Examples

```tcl
set pid [detach -dir C:/service -env {MODE production} -- daemon.exe]
puts "daemon started as $pid"
```

## Constraints

This is the one API that deliberately breaks Machteld's bounded-lifetime law.
Use it only for an intentionally independent service. A returned PID is not a
stable lifetime identity and can later be reused by Windows.

## See also

`machteld/command/run`, `machteld/command/child`,
`machteld/guide/execution-model`.
