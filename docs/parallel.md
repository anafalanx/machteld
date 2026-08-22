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
package require machteld 0.11.0

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

## Pool

```tcl
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
creation. Pool width is 1-256.

One request is in flight per worker. That makes a dead worker correspond to one
known item. The pool requeues that item and replaces the worker. After
`-maxtries`, the ordered reply is:

```tcl
{id 7 ok 0 code {MACHTELD POOL poison} msg {...}}
```

Retries are per item, so one poison request cannot exhaust a global death budget
and strand later work. A replacement that cannot launch makes `pool wait` raise
`POOL launch`. The director also rejects malformed replies and unexpected IDs as
protocol failures rather than assigning a result to the wrong request.

Each pool accepts exactly one submitted batch; create another pool for later
work. Replies are returned in that batch's submission order, independent of
completion order.
`pool info` reports width, live workers, pending/inflight/result counts, deaths,
requeues, completion, a fatal launch message, and a capped stderr tail. Stderr is
drained continuously because an unread pipe can fill and deadlock a worker.

`pool wait -timeout` controls the batch wait. It is distinct from a child's
creation-time `-timeout`. On timeout the pool remains owned by the caller; close
it or inspect it deliberately.

## Pmap

```tcl
set requests [lmap p $paths {list op digest path $p}]
set values [pmap $requests -width 8 -timeout 2m -- worker.exe]
set replies [pmap $requests -raw -width 8 -- worker.exe]
```

`pmap` creates a pool, submits one batch, waits, and closes the pool on every
path. The default returns plain result values. `-raw` returns full reply dicts.

Without `-raw`, the first failure in submission order is raised. A meaningful
handler error keeps its original code, so a `HASH notfound` in another process
can be trapped as `HASH notfound` here. A plain Tcl `error` with code `NONE`
becomes `PMAP failed`. Pool setup/wait failures are restated in the PMAP domain.

Use a pool when items are expensive enough to amortize JSON framing and process
scheduling, or when a responsive event loop matters. For tiny operations, an
ordinary Tcl loop is clearer and often faster.

## Engines (0.12.0)

From 0.12.0 the heavy-data counterpart to pools is the engine, commanded by
`macht` (see [the engine](engine.md)). The doctrine line between the two
families is short: **pools carry commands; engines hold data.** A pool item is
a named operation with a small payload, handled by a Tcl program with the full
palette - hash a file, probe a host, drive a tool. An engine holds a million
rows resident and runs Lua kernels over them, returning answers. Data
parallelism is shard threads *inside* one engine; task parallelism is a
program starting several engines *across* - threads inside, engines across,
and Tcl the only spawner. They compose: a pool worker may command an engine.

The section below describes the 0.11.0 in-process `macht -parallel`, which
0.12.0 replaces with the engine's `-shards`.

## Kernel-level parallelism (macht)

`worker`, `pool`, and `pmap` parallelize at the PROCESS level: separate
machteld hosts, message passing, tools and IO. `macht -parallel`
parallelizes at the KERNEL level: one process, N metered Lua states,
contiguous shards of a loaded table, integer partials reduced in Tcl. Use
pmap when the unit of work is a tool; use macht when the unit is arithmetic
over rows. They compose: a pmap worker may itself run macht. See
[the contract](contract.md) and `machteld/command/macht`.
