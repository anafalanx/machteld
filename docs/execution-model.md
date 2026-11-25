---
type: convention
title: Execution model
description: Linear defaults, explicit evented concurrency, and bounded lifetime.
tags: [machteld, execution, concurrency, jobobject]
---

# Execution model

Machteld is linear by default. `run`, `child wait`, and `pool wait` do not return
until a result or their applicable deadline. Their event behavior differs:
native waits block the calling thread; `pool wait` services Tcl events through
`vwait`. `watch read` and `pty read` poll immediately unless
given `-timeout`; with one, they block only to that visible bound. Code reads top
to bottom, and every requested deadline is visible at the call site.

Concurrency is explicit:

- `child start` returns immediately; `wait -any` multiplexes child and
  filesystem-watch handles.
- `pty expect` keeps an interactive exchange linear.
- `pool` uses nonblocking channels and `chan event` so several persistent workers
  can progress while Tcl/Tk's event loop remains responsive.
- `pmap` provides the bounded create/submit/wait/close lifecycle for one batch.

Native blocking commands do not promise to pump Tcl's event loop. Do not call a
long native wait on a GUI thread that must paint or service channel callbacks.
`pool wait`, and therefore `pmap`, instead enter a nested event loop: unrelated
timers and GUI callbacks can run before the call returns. They are not safe to
insert halfway through a widget/model update. A GUI can use immediate reads
from short `after` callbacks, or submit a pool batch and poll `pool info` from
the ordinary event loop, retrieving its results only once `done` is true.

## What a timeout does

| Call | Deadline and result | Work left owned afterwards |
| --- | --- | --- |
| `run -timeout d` | Whole-tree lifetime; returns `status timeout` | None; tree terminated and resources released |
| `child start -timeout d` | Autonomous whole-tree lifetime, even without a wait | Token remains until `child close` |
| `child wait -timeout d` | Observation only; returns `status running` if still active | Child continues; token remains |
| `pool create -timeout d` | Each worker tree's lifetime, including replacement workers | Pool remains; lost replies follow its retry policy |
| `pool wait -timeout d` | Observation of the batch; raises `POOL timeout` | Workers and pool remain owned and running |
| `pmap -timeout d` | Batch wait, not setup or total wall time; raises `PMAP timeout` | Its cleanup closes the pool and terminates remaining workers |
| `watch read -timeout d`, `pty read -timeout d` | Observation; empty result on timeout | Handle remains live |
| `pty expect -timeout d` | Observation; runs timeout body or raises `PTY timeout` | PTY remains live |
| `http ... -timeout d` | Per-network-phase timeout; raises `HTTP timeout` | Request handles released; a remote operation may already have happened |

Cleanup and callbacks can take additional time; none of these is a hard
real-time bound on when Tcl regains control. `wait` has no timeout, PTYs have no
autonomous lifetime deadline, and `store`'s five-second busy timeout is a lock
wait policy, not a whole-operation deadline. Close or kill cancels owned work;
it does not undo writes or prove that an unanswered operation had no effect.

## One background job

Load the Tcl package with `package require machteld::job 1.0`. It runs one
supervised child at a time and lets the caller return to the ordinary event
loop. The worker command is a Tcl list with one element per argument.

```tcl
package require machteld
package require machteld::job 1.0

# Run in a console host from a Tcl file or a .machteld archive.
if {$argv eq {--worker}} {
    fconfigure stdout -encoding utf-8 -translation lf
    puts {worker ready}
    exit 0
}

proc receive {job event data} {
    switch -- $event {
        lines    { foreach line $data { puts $line } }
        finished { set ::outcome [dict get $data phase] }
    }
}
set command [list {*}[app launch] --worker]
set job [::machteld::job::Job new receive]
try {
    $job start $command -console none -timeout 30s -mem 128M
    # The outer console loop. A Tk application already has an event loop.
    if {![info exists ::outcome]} { vwait ::outcome }
    puts $::outcome
} finally {
    $job destroy
}
```

A Tk application can use `$job start $command -console none` to launch a
background helper without a Windows console. The worker still receives its
standard pipes. The default is `-console default`. Use `-window hidden`
or `-window visible` when the helper should receive an initial show request.
The job receives a native completion event after its process tree exits and
delivers its final application callback after both output streams reach EOF.

Call `$job cancel` to stop the current run. The object can start again after
completion, failure, or cancellation. `start` returns 1 when the run is
accepted and 0 while running or after `$job close`. Call `$job destroy` when
its owner closes. The child receives EOF on stdin. It writes LF-terminated UTF-8
records to stdout and diagnostics to stderr. The caller chooses the record
format. An unterminated or invalid record fails the job.

The callback receives the job, an event, and its data. The events are
`started` (empty data), `lines` (a list of decoded records), `stderr` (a
chunk of diagnostic text), and `finished` (the terminal snapshot).
`$job snapshot` reports the phase, error text, recent diagnostic log, and
the native wait result when available. A nonzero exit or a child deadline
fails the run. A callback error fails the run and delivers `finished` once.
If `finished` itself raises an error, the snapshot records it. A callback
can cancel or destroy the job. Closing or
destroying it stops further callbacks.

The reader accepts at most 65,536 bytes per stdout record and delivers at
most 32 records per turn. It retains the last 8,192 characters of stderr.
Keep callback work bounded too. For a large result, send a reference or
small pages and render incrementally.

The Catalogue Lookup example in `examples/sqlite-lookup` opens a read-only
SQLite connection per page in a child process. It keeps one page in the Tk
view, keyed by the last displayed item ID. Cancelling the request or closing the
window releases the child even while SQLite is waiting on another connection.

## A small GUI-safe composition

The repository's `examples/project-inspector/main.tcl` uses this package.
Run it with `machteld.exe` and an optional directory argument. Its model
validates each worker record and maintains the application's rows and
progress while the job owns the child and its pipes.

Widget code subscribes to model snapshots and coalesces rendering. It does not
call `update` or `vwait` from a callback, so another event cannot enter halfway
through a widget update. A repeated start is rejected while work is active;
generation checks make callbacks from an older run harmless. Cancel and window
close remove handlers, cancel timers, and close the owned child. Errors remain
selectable/copyable, and a new inspection can recover after cancellation or
failure. Long logs and large directories cannot grow widget state indefinitely.

The inspector keeps at most 500 rows and uses the package defaults of a
30-second child deadline and a 128 MiB per-process memory limit. The child
runs trusted read-only application code. The example supports both the source-file entry route and a verified application archive. Its entry
dispatches an application-owned `--worker` role before opening the view, so the
same executable can launch supervised work without recursively opening another
application window. A `--headless` role exercises the same controller without
constructing the view; it supplements rather than replaces GUI acceptance.

`test/gui_model_test.tcl` exercises the model without Tk;
`test/gui_widget_test.tcl` constructs real widgets and tests their events,
keyboard/focus behavior, copyable errors, Unicode/space paths, resizing, Tk
scaling, and close-during-work. Actual desktop interaction remains a separate
acceptance check; a successful headless/model test alone is not GUI validation.

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

These jobs are not permissions sandboxes. Children retain the user's filesystem,
network, and credential access. `-dir` only sets their working directory and
`-env` overlays the inherited environment. `-mem` caps committed memory for each
process, not total tree memory or RSS; `-cpu` caps each process's cumulative
user-mode CPU time, not wall time or CPU utilization. See the
[runtime contract](contract.md) for the precise limits.

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

For large data, pass explicit paths in small protocol records and let the
application define file ownership, cleanup, and integrity checks. This is not
shared memory, a snapshot, or access confinement. Captured output and framed
transport have disclosed bounds; arbitrary Tcl lists, `dirs`/`links` results,
plain JSON, `store get`/`keys`, and `pty expect` transcripts can still consume
large amounts of host memory. Choose streaming channels, pruning, batch sizes,
and short terminal exchanges deliberately.
