---
type: guide
title: Parallel work
description: The worker protocol, supervised pools, retries, and pmap.
tags: [machteld, worker, pool, pmap, concurrency]
---

# Parallel work

Machteld parallelizes named operations over persistent supervised processes. It
does not serialize Tcl closures or evaluate scripts received from a director.
Code is installed once in a worker; requests carry data.

## Worker

```tcl
package require machteld 0.22

worker on digest {path {alg sha256}} {
    hash file $alg $path
}
worker on size {path} {
    file size $path
}
worker serve
```

`worker on name arglist body` creates a real proc in the caller's namespace. The
argument list is the request schema, including Tcl defaults. Operation names use
letters, digits, `_`, `.`, and `-`, and begin with a letter or underscore.
`worker ops` returns the registered schemas.

`worker serve` reads UTF-8 JSON objects, one line at a time, from stdin and writes
one JSON reply to stdout. Requests have an `id`, `op`, and fields named by the
handler arguments:

```text
{"id":7,"op":"digest","path":"C:/a.iso"}
{"id":7,"ok":1,"result":"9f86d0..."}
{"id":7,"ok":0,"code":["MACHTELD","HASH","notfound"],"msg":"..."}
```

Malformed JSON or a non-object produces `WORKER parse`; an unknown operation
produces `WORKER notfound`; a missing required field produces `WORKER usage`.
These are reply codes, so bad input does not kill the worker. A handler's own
structured error code is preserved in its failure reply.

Stdout is reserved for this protocol. Use `log`, stderr, or a file for diagnostics.
The wire is UTF-8 on both sides. Pool channels and worker input use binary
framing; worker output is explicitly configured for UTF-8 and LF. Complete
frames are bounded in UTF-8 bytes, so non-ASCII request and reply text crosses
intact. A handler
result that cannot be encoded as plain JSON is answered with a `WORKER failed`
reply rather than left unanswered.

## Pool

```tcl
# Reading a digest is replay-safe: permit up to three total attempts.
set p [pool create -width 8 -maxtries 3 -- worker.exe]
try {
    pool submit $p {
        {op digest path C:/a.iso}
        {op digest path C:/b.iso alg sha512}
    }
    set replies [pool wait $p -timeout 1m]
} finally {
    pool close $p
}
```

The pool starts workers with `child start -channels`; they are born into the
host-owned root job and their per-worker jobs, and die with the director.
`-arg0`, `-cpu`, `-dir`, `-env`, `-mem`, and launch `-timeout` are forwarded at
creation and replacement. Pool width is 1-256. Limits apply per worker process
and descendant, not to the sum of the pool: `-mem` caps committed memory and
`-cpu` caps cumulative user-mode CPU time. They do not limit the director's
memory or turn trusted workers into a permissions sandbox.

One request is in flight per worker. That makes a dead worker correspond to one
known item, but not to a known outcome: a handler may have completed a side
effect before losing its reply. Pool and pmap now default to `-maxtries 1`,
one attempt without automatic replay. Set a larger total-attempt limit only
for replay-safe work (read-only operations or application-level deduplication).
A reported handler failure is never replayed. After attempts are exhausted,
the ordered reply is:

```tcl
{id 7 ok 0 code {MACHTELD POOL poison} msg {...}}
```

The `poison` name does not prove the item caused the death or had no effect.
Explicit retries are per item, so one poison request cannot exhaust a global
death budget and strand later work. A replacement that cannot launch makes `pool wait` raise
`POOL launch`. The director also rejects malformed replies and unexpected IDs as
protocol failures rather than assigning a result to the wrong request.

Each pool accepts exactly one submitted batch; create another pool for later
work. Replies are returned in that batch's submission order, independent of
completion order.
`pool info` reports width, live workers, pending/inflight/result counts, deaths,
requeues, completion, a fatal message, limits/byte counts, and a capped stderr
tail. Stderr is drained continuously because an unread pipe can fill and
deadlock a worker.

`pool wait -timeout` controls the batch wait. It is distinct from a child's
creation-time `-timeout`. On timeout the pool remains owned by the caller; close
it or inspect it deliberately.
Creation-time deadlines kill worker trees. `pool close` cancels/releases owned
workers and invalidates the token; neither operation reverses completed side
effects. A callback closing a pool wakes an active wait with `POOL nohandle`.

Worker channels progress only while the director services Tcl events.
`pool wait` uses `vwait`, so unrelated timers and GUI callbacks can run before it
returns. Avoid calling it, or `pmap`, halfway through a UI update. An evented
controller can submit once, observe `pool info` from short callbacks, and fetch
results after `done` becomes true. A long native `run` or `child wait` on that
same thread stops pool channel progress until it returns.

## Bounded transport

Both `worker serve` and `pool create` default to `-maxframe 16777216`: 16 MiB
of UTF-8 bytes per JSON frame, excluding LF. Configure each endpoint separately
if larger frames are necessary. The pool also defaults to `-maxitems 10000`,
`-maxbatch 67108864` and `-maxresults 67108864`: count, accepted request bytes,
and retained reply bytes. Batch/reply totals include their LF delimiters.
Pmap exposes the same four limits. Limits are positive integers through
2147483647, not size-suffixed strings, and cannot be disabled.

Incoming framing is bounded before JSON decoding, including an unterminated
line. UTF-8 split across chunks remains intact. A complete final JSON value
without LF is accepted at EOF. Oversized submitted batches are rejected
atomically; overflow while receiving or queueing worker output/input terminates
the pool and raises `POOL limit` from wait (`PMAP limit` for pmap).
An oversized handler reply becomes `WORKER limit` reply data if that failure
envelope fits. Other internal channel callback failures become `POOL failed`
and also stop the workers, rather than leaving a silent stalled wait.

Each channel callback reads at most 64 KiB and handles at most 64 records,
including empty records, before yielding. Readable handlers on both streams
pause through an idle turn before rearming, allowing Tk's idle redraw/layout
work to run even during sustained pool traffic. Stderr is drained in bounded chunks
with a 64 KiB byte tail. Each worker input queue is bounded to one frame plus
LF. These are transport/retention limits, not total memory guarantees: Tcl
objects, JSON encoding and handler-owned data cost additional memory. Use
child `-mem` limits and pass paths for very large data. Paths convey names, not
snapshots or restricted capabilities: the application still owns file lifetime,
access policy, concurrent-change detection, and cleanup.

## Pmap

```tcl
set requests [lmap p $paths {list op digest path $p}]
set values [pmap $requests -width 8 -timeout 2m -- worker.exe]
set replies [pmap $requests -raw -width 8 -- worker.exe]
```

`pmap` creates a pool, submits one batch, waits, and closes the pool on every
path. The default returns plain result values. `-raw` returns full reply dicts.
Its timeout bounds the wait after creation/submission, not total call time.
Unlike `pool create`, `pmap` does not accept `-mem`, `-cpu`, `-env`, or `-dir`;
use an explicit pool when those launch controls are required.

Without `-raw`, the first failure in submission order is raised. A meaningful
handler error keeps its original code, so a `HASH notfound` in another process
can be trapped as `HASH notfound` here. A plain Tcl `error` with code `NONE`
becomes `PMAP failed`. Pool setup/wait failures are restated in the PMAP domain.

Use a pool when items are expensive enough to amortize JSON framing and process
scheduling, or when a responsive event loop matters. For tiny operations, an
ordinary Tcl loop is clearer and often faster.
