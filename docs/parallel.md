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
> A hot loop at a script's **top level** runs about **8× slower** than the same loop inside a
> `proc` — 1.75 µs against 0.22 µs per iteration here. Tcl compiles procedure bodies to local
> variable slots; top-level code resolves globals every time.
>
> This is not a footnote. The first version of the benchmark above put the loop at top level in
> the worker and inside a proc in the parent, and duly reported parallelism as a **0.79×
> slowdown**. It was measuring the compiler, not the cores. A worker whose hot loop sits at top
> level throws away most of its speed and will look exactly like "parallelism doesn't work here".

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
