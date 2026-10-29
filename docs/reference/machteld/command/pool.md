---
id: machteld/command/pool
type: command
title: pool
summary: Run one bounded ordered batch across supervised workers with explicit retry opt-in.
commands: pool, pool create, pool submit, pool wait, pool info, pool close
---

# pool

## Synopsis

```tcl
pool create ?-width n? ?-maxtries n? ?limit options? ?launch options? ?--? command ?arg ...?
pool submit token items
pool wait token ?-timeout duration?
pool info token
pool close token
```

## Arguments and options

`create` defaults to width `4` and `-maxtries 1` (one attempt, no replay).
Width is 1 through 256; maxtries is 1 through 2147483647 and counts total
attempts, not extra retries. It forwards `-arg0`, `-cpu`, `-dir`, `-env`, `-mem`, and
lifetime `-timeout` to each `child start -channels`. `items` is a list of request
dicts, each requiring `op`; the pool assigns sequential `id`. `wait -timeout`
defaults to five minutes and controls only the batch wait.

Limit options take integer counts from 1 through 2147483647, not size suffixes;
there is no unlimited setting:

| Option | Default | Counts |
| --- | ---: | --- |
| `-maxframe` | 16777216 (16 MiB) | One request or reply in UTF-8 bytes, excluding LF |
| `-maxitems` | 10000 | Requests in the submitted batch |
| `-maxbatch` | 67108864 (64 MiB) | Accepted request frames together, including each LF |
| `-maxresults` | 67108864 (64 MiB) | Retained reply frames together, including each LF |

The frame limit is enforced before incoming JSON decoding. It includes any
trailing CR. Worker-side `worker serve -maxframe` is configured separately;
raising the pool limit does not raise the worker limit. `-mem` is the separate
child-process memory cap, not a framing option.

## Results

`create` returns `pool#...`; `submit` and `close` return empty. `wait` returns
reply dicts in submission ID order. `info` returns `width`, `workers`, `pending`,
`inflight`, `results`, `dead`, `requeued`, `done`, `fatal`, and capped `stderr`,
plus `maxtries`, the four-limit `limits` dict, `batchbytes`, and `resultbytes`.
An item whose attempts end without a valid reply becomes reply data with code
`MACHTELD POOL poison`. That name does not prove the item caused the death.

## Errors

Raised codes are `POOL badvalue`, `POOL failed`, `POOL launch`, `POOL limit`,
`POOL nohandle`, `POOL timeout`, and `POOL usage`. Protocol-malformed workers
are treated as deaths and retried only when explicitly permitted by maxtries.
`poison` is reply data rather than a raised error. An unexpected internal
channel callback failure becomes `POOL failed`, wakes waiters and terminates
all owned workers. Frame, queued-output, and retained-result overflow likewise
terminate the workers and make `wait` raise `POOL limit`; they are not retried.
An oversized submitted batch is refused atomically before acceptance, allowing
a smaller batch to be submitted to the same pool.

## Lifetime and timeouts

A pool owns supervised channel-mode child trees. One item is in flight per
worker. A missing reply is an unknown outcome: the operation may already have
changed files, a database, or external state. The default therefore does not
replay it. Use `-maxtries` above 1 only for replay-safe operations (for example,
read-only work or application-level deduplication). Even explicit retries do
not provide exactly-once execution. A reported handler failure is a completed
reply and is never retried. Workers are replaced as needed to finish remaining
items. `wait` timeout leaves the pool owned and running;
`close` terminates workers and invalidates the token.
The creation-time `-timeout` is a process-tree deadline, so expiration kills a
worker and leaves an unanswered operation's outcome uncertain. `close` is
cancellation/release, not rollback; already completed side effects remain.
If an event callback closes the pool during `wait`, that wait wakes and raises
`POOL nohandle`. Completion or close already processed by the event loop is
not overwritten by a simultaneously ready observation timer.

## Examples

```tcl
# Digest is read-only, so opting into up to three total attempts is safe here.
set p [pool create -width 8 -maxtries 3 -- worker.exe]
try {
    pool submit $p {{op digest path a.iso} {op digest path b.iso}}
    set replies [pool wait $p -timeout 2m]
} finally {
    pool close $p
}
```

## Constraints

Each pool accepts exactly one submitted batch. Create another for later work.
Workers must implement the `worker serve` JSON-lines protocol and reserve
stdout for replies. The protocol channels are strict UTF-8 text: non-ASCII
request and reply text crosses intact, and a reply that is not valid UTF-8 is a
protocol death like malformed JSON. `submit` refuses an item that cannot encode
as plain JSON, such as one carrying a typed json value. Stderr is drained
continuously and retained only as a 65536-byte diagnostic tail (decoded with
replacement for invalid/split UTF-8). Each channel event reads at most 65536
bytes and handles at most 64 records, including empty records, then yields to
the event loop. Both stdout and stderr readable handlers pause through an
idle turn before rearming, so sustained pool traffic also gives Tk's idle
redraw/layout work an opportunity to run. UTF-8 split across reads is preserved, and a complete final
JSON object without LF is accepted at EOF. Each worker's nonblocking stdin
queue is capped at `maxframe + 1` bytes, including LF.

Limits bound transport and retained wire data, not every Tcl allocation: caller
requests and handler results already exist before serialization, decoded Tcl
objects and JSON escaping have overhead, and each worker has its own frame
buffer. Set a suitable width and child `-mem` cap for the workload. Large
payloads are better passed by file path than embedded repeatedly in JSON.

## Subcommands

<a id="create"></a>
### create

#### Synopsis

`pool create ?-width n? ?-maxtries n? ?-maxframe bytes? ?-maxitems n?
?-maxbatch bytes? ?-maxresults bytes? ?-arg0 word? ?-cpu d? ?-dir path?
?-env dict? ?-mem size? ?-timeout d? ?--? command ?arg ...?`

#### Arguments and options

Starts `width` identical workers. The launch timeout is each worker's autonomous
process-tree lifetime, not the future pool wait bound.

#### Results

Returns a token only after all initial workers launch.

#### Errors

Bad bounds/options report `badvalue`/`usage`; any initial spawn failure reports
`POOL launch` after closing already-created workers.

#### Lifetime and timeouts

Workers live until close, death/replacement, launch deadline, or host teardown.

#### Examples

`set p [pool create -width 4 -- $exe --worker]`

#### Constraints

Persistent workers amortize launch only when each item has meaningful work.
Memory and CPU limits apply separately to each worker process and descendant,
not the sum of the pool or the director. Memory means committed memory, not RSS;
CPU means cumulative user-mode time, not elapsed time or a utilization cap.
Working directory and environment overrides do not confine authority.

#### See also

`machteld/command/worker#serve`.

<a id="submit"></a>
### submit

#### Synopsis

`pool submit token items`

#### Arguments and options

Each list element must be a dict with `op`; caller-supplied `id` is replaced.

#### Results

Returns empty after queueing and starting feeds.

#### Errors

Malformed items report `POOL badvalue`; second submission reports `POOL usage`.
Batch count/byte or individual frame overflow reports `POOL limit` atomically.

#### Lifetime and timeouts

Items remain owned until replies, poison, fatal replacement failure, or close.

#### Examples

`pool submit $p [list [dict create op size path $path]]`

#### Constraints

Exactly one batch per pool, including an empty batch.

#### See also

`machteld/command/pool#wait`.

<a id="wait"></a>
### wait

#### Synopsis

`pool wait token ?-timeout duration?`

#### Arguments and options

Default observation bound is `5m`.

#### Results

Returns all replies ordered by assigned submission ID.

#### Errors

Timeout is raised as `POOL timeout`; replacement launch failure is `POOL launch`.
Transport/result overflow is `POOL limit`; an internal event failure is `POOL failed`.
Closing the pool from an event callback during the wait raises `POOL nohandle`.

#### Lifetime and timeouts

A timeout does not cancel work or close the pool. This wait runs Tcl's event
loop through `vwait`: unrelated timers and GUI callbacks may run before return.
The bound covers waiting, not initial launches, submission, or cleanup.

#### Examples

`set replies [pool wait $p -timeout 30s]`

#### Constraints

Call only after `submit`; always arrange a later `close`. Avoid a nested wait
inside a partially completed widget/model update. An evented controller can
poll `pool info` and collect results after `done` is true; worker progress needs
the Tcl event loop to remain serviced.

#### See also

`machteld/command/pool#info`.

<a id="info"></a>
### info

#### Synopsis

`pool info token`

#### Arguments and options

Takes one pool token.

#### Results

Returns the fixed operational-state dict described above.

#### Errors

Stale tokens report `POOL nohandle`.

#### Lifetime and timeouts

Non-consuming, immediate snapshot.

#### Examples

`puts [dict get [pool info $p] stderr]`

#### Constraints

Counts can change immediately as channel events run.

#### See also

`machteld/command/pool#wait`.

<a id="close"></a>
### close

#### Synopsis

`pool close token`

#### Arguments and options

Takes one live pool token.

#### Results

Returns empty.

#### Errors

A stale token reports `POOL nohandle`; individual child cleanup is best effort.

#### Lifetime and timeouts

Disables channel events, closes worker stdin, closes each child tree, discards
pending/results state, and invalidates the token.
An active `wait` is woken and reports `POOL nohandle`; its observation timer is
cancelled on exit, including error paths.

#### Examples

`try { ... } finally { pool close $p }`

#### Constraints

Unread replies are lost.

#### See also

`machteld/command/pmap`.

## See also

`machteld/command/worker`, `machteld/command/pmap`,
`machteld/guide/parallel`.
