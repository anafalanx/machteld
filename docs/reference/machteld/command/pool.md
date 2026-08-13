---
id: machteld/command/pool
type: command
title: pool
summary: Run one ordered batch across persistent supervised worker processes with bounded retry.
commands: pool, pool create, pool submit, pool wait, pool info, pool close
---

# pool

## Synopsis

```tcl
pool create ?-width n? ?-maxtries n? ?launch options? ?--? command ?arg ...?
pool submit token items
pool wait token ?-timeout duration?
pool info token
pool close token
```

## Arguments and options

`create` defaults to width `4` and `-maxtries 3`; width is 1 through 256 and
maxtries is at least 1. It forwards `-arg0`, `-cpu`, `-dir`, `-env`, `-mem`, and
lifetime `-timeout` to each `child start -channels`. `items` is a list of request
dicts, each requiring `op`; the pool assigns sequential `id`. `wait -timeout`
defaults to five minutes and controls only the batch wait.

## Results

`create` returns `pool#...`; `submit` and `close` return empty. `wait` returns
reply dicts in submission ID order. `info` returns `width`, `workers`, `pending`,
`inflight`, `results`, `dead`, `requeued`, `done`, `fatal`, and capped `stderr`.
A repeatedly fatal item becomes reply data with code `MACHTELD POOL poison`.

## Errors

Raised codes are `POOL badvalue`, `POOL launch`, `POOL nohandle`,
`POOL timeout`, and `POOL usage`. Protocol-malformed workers are treated as
deaths and retried. `poison` is reply data rather than a raised error.

## Lifetime and timeouts

A pool owns supervised channel-mode child trees. One item is in flight per
worker. A worker death requeues that known item and spawns a replacement until
its per-item attempt limit. `wait` timeout leaves the pool owned and running;
`close` terminates workers and invalidates the token.

## Examples

```tcl
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
stdout for replies. Stderr is drained continuously and retained only as a
bounded diagnostic tail.

## Subcommands

<a id="create"></a>
### create

#### Synopsis

`pool create ?-width n? ?-maxtries n? ?-arg0 word? ?-cpu d? ?-dir path?
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

#### Lifetime and timeouts

A timeout does not cancel work or close the pool.

#### Examples

`set replies [pool wait $p -timeout 30s]`

#### Constraints

Call only after `submit`; always arrange a later `close`.

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

#### Examples

`try { ... } finally { pool close $p }`

#### Constraints

Unread replies are lost.

#### See also

`machteld/command/pmap`.

## See also

`machteld/command/worker`, `machteld/command/pmap`,
`machteld/guide/parallel`.
