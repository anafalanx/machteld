---
type: study
title: Parallelism, measured
description: What machteld runs in parallel today, what limits it, and why the store was studied as a work queue and then refused.
tags: [machteld, parallel, store, study]
timestamp: 2026-08-09
---

# Parallelism, measured

Measured on a 12-logical-core Windows 11 box with machteld 0.3.0. Every number came from a run.

## What works today

Parallelism here is **process-level**, deliberately: `Thread` is not linked and should not be
([stdlib](stdlib.md)). `child start` plus `wait -any` is a worker pool, and **the interpreter
that calls them is the director** — a separate director process buys nothing unless the work has
to outlive the caller.

| | |
|---|---|
| 8 CPU-bound children, overlap factor | **7.46×** |
| 12 items × 92 ms, end-to-end speedup | **2.98×** |
| 12 items × 429 ms, end-to-end speedup | **3.19×** |
| Worker boot cost | **~26 ms** |
| Job-object CPU or affinity cap | none — only `KILL_ON_JOB_CLOSE` |

The gap between 7.46× overlap and ~3× end-to-end is boot cost plus hyperthreading: twelve
logical cores are about six physical ones for this kind of work.

**The 26 ms boot sets the crossover.** Below roughly 25–30 ms of work per item, spawning costs
more than it saves. A bounded pool is about twelve lines over `child start` and `wait -any`,
though 24 items spawned all at once (736 ms) beat every bounded width tried (869–1256 ms):
Windows schedules them fine, so a pool bounds memory and handles rather than buying speed.

> ## The trap to know before writing any worker
>
> A hot loop at a script's **top level** runs **3.6× slower** than the same loop inside a `proc`:
> 1488 ms against 415 ms for the same two million iterations in the same spawned child. In-process
> the ratio is 2.2×.
>
> *(An earlier draft of this file said 8×. That compared a child's top-level loop against the
> parent's proc, so it charged the difference between two processes to the difference between two
> scopes. The number above is the same script twice, in one child.)*
>
> The cause is not local-versus-global variables, which is the intuitive guess and is wrong: a
> proc using `global` runs 428 ms against 401 ms for one using locals, because `global` installs
> a **link in the local frame** and keeps the slot. What matters is being inside a procedure body
> at all — that is what gives the compiler a frame to assign slots in. `apply` at top level is
> equally fast (413 ms), which pins it: an anonymous proc is still a proc.
>
> This is not a footnote. The first version of the benchmark above put the loop at top level in
> the worker and inside a proc in the parent, and duly reported parallelism as a **0.79×
> slowdown**. It was measuring the compiler, not the cores. A worker whose hot loop sits at top
> level throws away most of its speed and will look exactly like "parallelism doesn't work here".

## What this is good for

One number decides most cases: **a worker costs 26 ms to start**, so an item must be worth far
more than that. Measured on the two shapes that matter:

| shape | per item | speedup |
|---|---|---|
| **an external program per item** (`findstr` over 14 files) | 40 ms | **4.84×** |
| CPU-bound Tcl in a worker | 50 ms | 3.48× |
| the same 14 files hashed **in-process** by `hash file` | 0.4 ms | **do not** — 6 ms total |

External programs parallelise best because they are partly latency-bound and overlap rather than
saturating cores. Pure CPU work saturates twelve logical cores at about 3.5×, which is roughly
what six physical ones can give.

**The work it suits, then:**

- **Fan-out over external programs** — compile, convert, sign, lint, test, package. This is the
  archetype, it is what machteld is *for*, and it is where the numbers are best. Any loop of
  `run` calls over a list is a candidate.
- **Long batches**, minutes upward, where losing progress to a crash actually costs something —
  which is where the durable half earns its place rather than being ceremony.
- **Work that outlives its launcher**: queued by one session, executed later, collected by
  something that was not running when it started. `child`/`wait` cannot do this at all.
- **Runs worth watching.** With WAL the director reads a worker's results *while it writes them*,
  so a long job has a progress view instead of a silence followed by an answer.

**The work it does not suit** — and the last row of the table is the one people get wrong:

- **Anything a palette verb already does in-process.** Fourteen files hashed take 6 ms; spawning
  fourteen workers to do it costs 364 ms in startup alone. `hash`, `json`, `ps` and `store` are C
  in the same process. Parallelising them is pure loss.
- **Items under ~30 ms.** Spawn dominates. Fine-grained data parallelism needs persistent workers,
  which needs `child send`.
- **Anything wanting shared mutable state.** These are processes; there is no shared memory, and
  SQLite is a lock rather than a cache.
- **Bulk data through the database.** It is a coordination point. Move payloads through files both
  sides can see, or the child's own stdout.
- **More than one machine.** SQLite over SMB or NFS is a documented hazard.

## The store as a work queue — studied, then refused

SQLite is already in the exe, it is durable, and it is visible to every process on the machine
including sessions that have not started yet — the one thing `child`/`wait` cannot do at all. So
it was built and measured properly before being turned down.

**It works.** Three small changes to `src/store.c` were enough: `PRAGMA journal_mode=WAL`,
`sqlite3_busy_timeout(5000)`, and `store del` returning `sqlite3_changes()`. That third one is
the whole trick — two processes racing to `del` the same key both succeed, but **exactly one is
told it removed a row**, which is an atomic claim with no new verb at all.

Measured, with those changes in place:

- 6 writers × 200 puts: **1200 succeeded, 0 failed** (before: five of six died on `store open`)
- 4000 jobs across 6 processes: **12,500 claims/sec, every job claimed exactly once, none lost**
- correctness held at 2, 6, 12 and 24 workers — 6000/6000 every time

Two findings from it are worth keeping regardless of the verdict:

**fsync was the entire throughput story.** At `synchronous=FULL` the queue managed 275
claims/sec. One pragma — `synchronous=NORMAL`, the setting WAL is normally paired with — moved
`put` from 410/sec to 29,412/sec and `del` from 579/sec to 35,714/sec. **72×.** And it disproved
the obvious suspect: the `keys` full scan, which the KV surface offers no cursor to avoid, costs
**1 ms for 2000 keys** and never mattered.

**Throughput falls as workers rise** — 14,151 claims/sec at 2 workers, 6,749 at 24 — because
SQLite has **one writer at a time**. More workers buy contention, not throughput. Which gives the
sentence worth carrying forward:

> **SQLite is a coordination point, not a parallel data path.**

### Why it was refused anyway

**Decision, 2026-08-09: the store is not the parallelism mechanism.**

Not on the numbers — the numbers were good. On what it would have made `store` into. `store` is a
tool's own key-value state; a work queue is a different thing with different rules, and putting
both in one file behind one lock conflates them. [Creed](creed.md) 6 asks for one way to do each
thing, and this would have been one thing doing two.

The durability question was the tell rather than the obstacle. A queue wants `synchronous=NORMAL`
and is right to; state a user keeps may want `FULL`. When a single knob cannot serve both
defensible answers, that is usually because two different things are sharing one mechanism. The
change was measured, recorded here, and reverted.

If a durable cross-process queue is ever genuinely wanted, it should arrive as **its own verb
with its own file**, free to choose its own durability — not as a second personality for `store`.

## A separate mechanism — the shape the evidence points at

**Decided: whatever this becomes, it is not `store`.** What follows is design, not built.

The proposal that started it: a director writes tasks to a database, workers pick them up, each
worker writes results to **its own** database, and the director reads them all. The claim was
*never any write contention*.

### What the measurements say about it

**The results half is right, and better than it looks.** With realistic work — 96 items of ~50 ms
each, one durable result row written per item — it reaches **3.48× on 8 workers with 96/96 rows
collected**. The database cost disappears into the work.

**But "no write contention" is only true at the SQLite level.** Separate files remove *lock*
contention and cannot remove *disk* contention. Eight workers writing 400 trivial rows each to
eight separate files aggregate **175 rows/sec — the same as one worker's 156**. Every write is
its own transaction paying an fsync at ~2.4 ms, and eight processes syncing independently still
queue at the storage layer.

Those two results are not in conflict; they bound each other. **The fsync ceiling is roughly 400
writes/sec on this disk, and it only bites when an item's own work is smaller than 2.4 ms.**
machteld cannot profitably run items that small anyway — a worker costs 26 ms to start. So at the
grain machteld actually works, per-item durability is free; at finer grain, nothing about file
layout saves it and only **batched commits** would.

### The refinement worth taking

Push the instinct all the way and the design gets better: **every file has exactly one writer, for
its whole life.**

```
tasks-N.db     written only by the director,   read only by worker N
results-N.db   written only by worker N,       read only by the director
```

Now there is no claim, no arbitration and no lock contention **by construction** rather than by
timing. A worker never writes a file anyone else touches, and neither does the director.

The obvious objection is load balancing: a static split leaves stragglers, which is visible above
as the plateau between 8 workers (2103 ms) and 12 (2096 ms) — twelve workers with eight items
each finish unevenly and the slowest sets the wall clock. The answer keeps the single-writer rule
intact: **the director tops up**. It watches each worker's results file, and when a worker is
running low it appends more tasks to that worker's own task file. Balance is restored without any
file ever gaining a second writer.

The cost is polling latency on both sides, which at 50 ms-per-item grain is noise.

### What such a mechanism has to provide

Whatever surface this takes, the measurements say it needs four things `store` does not have:

1. **Its own file, and its own durability choice** — a queue may pick `synchronous=NORMAL`; a
   user's state may not want to.
2. **WAL**, so the director can read a worker's results *while it is still writing them*. That is
   the capability nothing else here offers: progress visible mid-flight, not at exit.
3. **Batched commits** — one fsync per batch rather than per row. This is the only thing that
   moves the 400/sec ceiling, and no amount of file separation substitutes for it.
4. **Append and range-read**, not key-value. Results are a sequence, and `keys`-then-`get` is the
   wrong shape for reading 10,000 of them.

### Two candidate shapes

- **A job verb** — `queue`/`take`/`post`/`drain`, with the pattern built in. Convenient, and it
  fixes one policy for everyone.
- **A thin table verb** — append rows to your own file, read ranges, commit in batches, and let
  the director/worker pattern live in the prelude as ordinary Tcl.

[Rule 4](direction.md) argues for the second: C only for what Tcl cannot reach. Tcl cannot reach
SQLite, but it can certainly express a queue given a table — and a table is useful for things
that are not queues, while a queue is not.

## What remains open

- **`child` cannot feed a running child.** Its subcommands are `start wait kill info list close`;
  `-stdin` is a fixed string supplied once. So there are no persistent workers over plain
  children, and every item pays the 26 ms boot. `child send` plus streaming reads is the change
  that would unlock fine-grained data parallelism. (`pty send` can feed a live child, but a pty
  is a terminal, not a data pipe.)
- **Two machteld processes cannot share one store file.** `store open` fails outright with
  *database is locked*, because `CREATE TABLE IF NOT EXISTS` takes a write lock with no busy
  timeout. This is unrelated to queues — two instances of the same wrapped tool hit it — and is
  worth its own decision rather than riding along with a parallelism feature that was refused.
