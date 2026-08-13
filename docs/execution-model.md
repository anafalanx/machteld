---
type: convention
title: Execution model
description: Linear defaults, explicit evented concurrency, and bounded lifetime.
tags: [machteld, execution, concurrency, jobobject]
---

# Execution model

Machteld is linear by default. `run`, `child wait`, and `pool wait` block until a
result or explicit deadline. `watch read` and `pty read` poll immediately unless
given `-timeout`; with one, they block only to that visible bound. Code reads top
to bottom, and every requested deadline is visible at the call site.

Concurrency is explicit:

- `child start` returns immediately; `wait -any` multiplexes child and
  filesystem-watch handles.
- `pty expect` keeps an interactive exchange linear.
- `pool` uses nonblocking channels and `chan event` so several persistent workers
  can progress while Tcl/Tk's event loop remains responsive.
- `pmap` provides the bounded create/submit/wait/close lifecycle for one batch.

Blocking commands do not promise to pump Tcl's event loop. Do not call a long
blocking wait on a GUI thread that must paint or service channel callbacks. A GUI
can schedule short timed reads from `after`, or use the evented pool interface.

## Lifetime law

The host owns, but is not a member of, a root Windows Job Object configured for
kill-on-close. Every supervised child or PTY is born into that root job and a
narrower per-command job. Closing the host therefore closes the process trees it
owns, not only their first PIDs, without replacing the host's own exit status
with a job-termination status.

```tcl
scope {
    set server [child start -- server.exe]
    run -timeout 30s -- client.exe
} ;# server and its descendants cannot escape the brace
```

`scope` snapshots the child registry, evaluates its body in the caller, closes
children created inside it on every return/error path, then preserves the body's
result or error. Scopes nest naturally.

`detach -- daemon.exe` is the deliberate exception. Success means the new process
has been verified to belong to no Windows job, so its independent tree survives
the calling host. An enclosing Windows job can forbid breakaway; Machteld then
reports `{MACHTELD DETACH launch}` instead of returning a still-attached PID.
Its use should be visible and rare.

Opaque handles have an owner and an explicit `close`. `info` observes without
draining. A handle is never reconstructed from a PID or accepted after close.

## Process I/O

Capture is the default for automation. `run` returns stdout and stderr in its
result dict; `child start -channels` exposes pipes for protocols, so its caller
drains output and closes stdin to signal EOF before an EOF-driven worker can
complete. `pty` owns terminal semantics. `run -inherit` is the explicit
human-facing path for color, pagers,
Ctrl-C, and a child's direct use of the current terminal.

Channels and protocol data have different jobs. A worker's stdout is its
JSON-lines wire and must contain nothing else; stderr is drained for diagnostics.
This separation prevents an ordinary log line from becoming a false reply.
