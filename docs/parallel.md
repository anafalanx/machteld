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
| Worker boot cost | **17.1 ms** external program / **44.5 ms** machteld child |
| Concurrent start rate, width 12 | **~90 a second** — spawning does not parallelise |
| Job-object CPU or affinity cap | none — only `KILL_ON_JOB_CLOSE` |

The gap between 7.46× overlap and ~3× end-to-end is boot cost plus hyperthreading: twelve
logical cores are about six physical ones for this kind of work.

**The boot cost sets the crossover.** Below roughly 25–30 ms of work per item, spawning costs
more than it saves — **confirmed by measurement later** (see the four-arm study below), including
the tempting objection that spawns overlap so the real crossover must be far lower. They do not
overlap well. Re-measured with the child kind named, since "26 ms" was one number for two very
different things: an external program costs **17.1 ms** to start and a machteld child **44.5 ms**,
and under 12-way concurrency the *aggregate* rate is only ~90 starts a second rather than the ~270
that dividing by width would predict. A bounded pool is about twelve lines over `child start` and `wait -any`,
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

One number decides most cases: **a fresh worker costs 17–45 ms to start** depending on whether it
is an external program or a machteld child, so an item must be worth far more than that. Measured
on the two shapes that matter:

| shape | per item | speedup |
|---|---|---|
| **an external program per item** (`findstr` over 14 files) | 40 ms | **4.84×** |
| CPU-bound Tcl in a worker | 50 ms | 3.48× |
| the same 14 files hashed **in-process** by `hash file` | 0.4 ms | **do not** — 6 ms total |

External programs parallelise best because they are partly latency-bound and overlap rather than
saturating cores. Pure CPU work saturates twelve logical cores at **about 3.2×** — measured later
over jobs long enough for startup to amortise, which is where a figure like this has to come from;
the 3.48× above is the same wall seen through a shorter run. Roughly what six physical cores give.

*(All of this describes `child start` per item, which is what existed when it was written. The
[worker pool](#built-and-measured-in-a-shipped-tool) changes the arithmetic and is measured against
these same alternatives further down.)*

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
machteld could not profitably run items that small when this was written — a fresh worker costs
17–45 ms to start. So at the grain machteld actually worked, per-item durability was free; at finer
grain, nothing about file layout saves it and only **batched commits** would. **The pool moves that
boundary**: a persistent worker takes an item for 159 µs, so items *below* 2.4 ms are now reachable
— and for those, per-item durability would no longer be free. Nothing here depends on it today,
because the durable half was refused, but a future ledger would have to batch.

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

## Is SQLite even the right technology? — measured, and no

The design above assumed SQLite because it was already in the exe, which is exactly the reasoning
that deserves testing. Writing 2000 results four ways:

| mechanism | rate |
|---|---|
| SQLite, one `put` per result | 102/sec |
| one file per result, write and close | 400/sec |
| one file per result, `.tmp` + atomic rename | 152/sec |
| **one append-only log per worker** | **105,263/sec** |

**A thousandfold.** SQLite pays a transaction, a journal write and a B-tree update per row; an
append pays a buffered write. Per-file schemes lose to NTFS metadata cost, and atomic rename —
the classic lock-free commit — costs more than writing the file did.

And the log is not merely faster; it answers the two things the SQLite design could not:

- **Mid-flight readable with no WAL and no ceremony.** A director watching a running worker saw
  its log grow 2 → 4 → 7 → 8 lines. Progress visibility is just reading a file.
- **Notification without polling.** `watch` on the directory fired 5 events as the worker
  appended. The polling gap in the queue design is closed by a verb machteld already has.

It is also crash-honest: a half-written final line is visibly incomplete, and every earlier line
is intact. With `json` the format is one object per line — machine-legible and human-legible at
once ([creed](creed.md) 2), and readable by anything.

**So the mechanism the evidence actually points at is: an append-only log per worker, `watch` for
notification, `json` for the line format — and no database at all.** Every file still has exactly
one writer for life, which was the good half of the original instinct.

What SQLite would still be better at is **mutable state**: marking an item pending → in flight →
done is an update, and a log cannot update. If a task ledger ever needs that, it is a reason to
reach for a database. A results stream is not that; it is read once, whole.

## Should this become the main mechanism for governing external processes?

**No — because it governs a different noun.** A queue governs *work items*; `child` governs
*processes*. The queue does not replace the process verbs, it sits on them: a worker still has to
be launched, capped, timed out and tree-killed, and that is exactly what `child` does.

The tax argument turns out not to be the reason. A log write costs **0.01 ms against a ~11 ms
process launch** — a 0.07% overhead, so ledgering every launch would be affordable. The reasons
are about shape:

- **`run` is synchronous and returns a dict.** Routing it through a queue makes it asynchronous,
  which is a different thing wearing the same name.
- **The job-object guarantees are the differentiator** — born-in-job, die-with-parent, whole-tree
  kill, memory and CPU caps. A queue has none of these; it needs `child` underneath to get them.
- **`pty` cannot be queued at all.** Interactive steering is inherently synchronous and stateful.
- **`scope` is lexical** — bounded lifetime by structure, an idea a queue does not express.

There *is* a version of the question with legs, and it is worth naming precisely because it is
not this one: a **supervisor** — a durable ledger of what *should* be running, so a set of
long-lived processes survives the director's own restart. That is supervision over time rather
than invocation, it is genuinely absent today, and it would be built *on* `child` rather than
instead of it.

## The thorough design — workers are channels

Everything above treats a worker as a process you start, wait for, and reap. That is the wrong
noun. **In Tcl a worker is a channel**, and once it is, the whole concurrency machinery Tcl
already has applies without inventing anything.

### The finding that reorganises it

Tcl core already opens a bidirectional pipe to a live subprocess:

```tcl
set ch [open "|[list $MT worker.tcl]" r+]
fconfigure $ch -translation lf -buffering line
puts $ch $request ; set answer [gets $ch]
```

Measured: **159 µs per round trip, against 26,000 µs to spawn a fresh worker — a 164× improvement
in granularity.** (Re-measured later, a machteld child costs **44,500 µs** to start, which makes the
ratio ~280× rather than 164×. The spike's figure came from a lighter child; the argument only got
stronger.) And it drives the event loop natively: a pool built on `chan event` and `vwait`, with no
polling anywhere, ran 300 items of 13 ms each at **3.23× on 12 workers** — work that is *below* the
spawn crossover and that `child start` cannot parallelise at all.

So the missing piece was never the transport. Tcl has it. **What Tcl's pipe lacks is
supervision**: a child opened that way is not born in a job object, cannot be tree-killed, does
not die with its parent, takes no memory or CPU cap, never appears in `child list`, and is not
cleaned up by `scope`.

That is the whole of the C work, and it is exactly machteld's thesis — *Tcl for the language, C
for the kernel surface*.

### Why channels, and not `child send` / `child recv`

Two reasons, and both are about fitting rather than taste.

**Tcl's own thread model is message-passing between isolated interpreters.** Each thread gets its
own interpreter; variables are not shared, and `thread::send` marshals a script across. A pool of
worker *processes* is therefore architecturally identical to Tcl threading — with stronger
isolation, no C extension thread-safety hazard, and a slower start. The process design is not a
compromise version of threads; **it is the same model with a different boundary.**

**Tcl's async primitive is the event loop over channels** — `chan event`, `fconfigure -blocking
0`, `vwait`, and `coroutine` for sequential-looking code on top. A design whose workers *are*
channels inherits all of that. A pair of `send`/`recv` verbs would be a second, poorer copy of it,
and would extend the grammar where [rule 1](direction.md) asks for vocabulary.

### The layers

**L0 — C: `child start` gains a channel mode.** The one genuinely new thing. The child is born in
a job object with every existing guarantee, *and* its stdin/stdout come back as Tcl channels via
`Tcl_MakeFileChannel`. This is exclusive with capture: `child_t` drains the pipes with reader
threads into buffers today, and one pipe cannot have two consumers. A channel-mode child gives
channels instead of `out` / `err`, and the manifest has to say so.

**L1 — Tcl: the protocol is JSON lines.** One object per line, so `gets` reads exactly one and
there is no framing to invent. `json` is already in the palette, and one-object-per-line is
machine-legible and human-legible at once — [creed](creed.md) 2 rather than a coincidence.

**L2 — Tcl: the worker side.** A dispatch loop that reads a line, calls a registered handler,
writes a line. Handlers live in **procs**, and that is not style: a hot loop at top level runs
3.6× slower, so the worker template must put the work inside a procedure or throw most of its
speed away.

**L3 — Tcl: the pool, event-driven.** `chan event $ch readable` per worker, and the event loop
does the multiplexing that `wait -any` does by blocking. Backpressure through non-blocking writes
and writable events. No polling anywhere.

**L4 — Tcl: `pmap`, as a coroutine.** The caller writes sequential code; underneath it yields
while the event loop feeds results back. This is the Tcl 8.6+ idiom for waiting without blocking
the event loop, and it is what keeps a Tk tool responsive while a pool runs.

**L5 — Tcl, optional: the durable ledger.** The append-only log — 105,263 writes/sec, readable
mid-flight, `watch`-notifiable — for work that must outlive the director. Not the transport; the
transport is the channel.

### What comes free, and what has to be faced

Free, because workers are `child`ren: born-in-job, die-with-parent, whole-tree kill, memory and
CPU caps, `-timeout`, visibility in `child list`, cleanup by `scope` at the closing brace. Free,
because errors are dicts: a worker's `{MACHTELD X y}` crosses the line as a field and is re-raised
by the pool, so the error contract holds **across a process boundary**.

The hard parts, named rather than glossed:

- **Deadlock by pipe buffer.** A worker writing more than the pipe holds while the director is not
  reading will block, and so will the director. Non-blocking channels with `chan event` in both
  directions is the answer, and it is the part most likely to be subtly wrong on Windows.
- **Capture versus channels** is an either/or per child, and the manifest must declare it.
- **A worker dying mid-item.** The channel reaches EOF with an item outstanding: the pool must
  detect it, requeue, and decide when a repeatedly-fatal item poisons the run.
- **The line format becomes a compatibility surface** the moment a wrapped tool ships a worker.
- **Amortisation only pays if workers are reused.** The start cost is now paid once per worker
  rather than once per item — but a pool created per call throws that straight back. **Measured
  afterwards this is the sharpest constraint of the five**: twelve workers cost a few hundred
  milliseconds to raise, so a job under a second gets barely two thirds of the available speedup
  and a job under ~4 s has not finished paying for its own pool.

### What it buys

Granularity, which is the thing machteld cannot have today. The crossover moves from ~26 ms of
work per item to roughly **1 ms** — the difference between *parallelism is for spawning programs*
and *parallelism is for anything worth a millisecond*.

> **Measured afterwards, this is right about the item and wrong about the job.** Per *item* the
> claim holds and then some: 41× the throughput of spawn-per-item at half-millisecond items. But
> granularity was only half the story — the pool has a fixed start cost of a few hundred
> milliseconds, so the *job* has to be worth about four seconds before any of the gain arrives.
> Small items, yes; small jobs, no. And against a hand-written static partition the pool buys no
> throughput at all — it matches it. See below.

## Built, and measured in a shipped tool

The design above is built: `child start -channels`, `worker`, `pool`, `pmap`. The proof that it
works where it has to is [`sums`](../tool/sums/main.tcl) — a wrapped console exe that hashes a
tree using **copies of itself** as workers (`sums.exe --worker`, one artefact, no tclsh, no
worker script on disk). Its selftest passes both wrapped and run as a script, and asserts the
thing worth asserting: the pool's digests equal the ones this process computes alone.

**A cold first pass is not a sequential time, and getting that wrong produced a 38× "speedup".**
The first version of the measurement ran sequential first *on the reasoning that the pool must
not inherit a warm cache* — which is backwards. The first pass pays for every cold read and, on
Windows, for the antivirus filter's first look at each file; the second reads from the OS cache.
Sequential 73.6 s against a pool at 1.9 s is not parallelism: twelve logical cores cannot make
anything go 38 times faster. The tool now does a discarded warm-up pass and times both halves
warm, and prints the cold pass on its own line, where it belongs — for a tree read once, that
number is what a user actually experiences.

Warm, on this box, hashing **machteld's own tree** — 8,221 files, 368 MB, 45 KB average:

| width | sequential | pool | |
|---|---|---|---|
| 12 | 2047.9 ms | 1609.2 ms | **1.27×** |
| 4 | 1926.5 ms | 1691.5 ms | 1.14× |
| 1 | 1847.0 ms | 4817.5 ms | **0.38×** |

Small files are a poor pool workload, exactly as the `hash file` row above predicts, and **width 1
is the honest picture of the protocol**: one worker, no concurrency to pay for the round trip, and
the run takes 2.6× as long. A pool is not free and this is what it costs.

Where the items are worth having, on **1 GB in 272 files** (3.67 MB average), width 12:

| digest | sequential | pool | speedup | sequential throughput |
|---|---|---|---|---|
| `md5` | 3100.9 ms | 882.2 ms | **3.51×** | 322 MB/s |
| `sha512` | 3161.8 ms | 1150.7 ms | 2.75× | 316 MB/s |
| `sha1` | 2739.0 ms | 1007.3 ms | 2.72× | 364 MB/s |
| `sha256` | 1592.8 ms | 681.6 ms | 2.34× | 627 MB/s |

**The speedup is ordered by how much CPU each byte costs, inversely.** `sha256` is the *fastest*
sequentially and parallelises *worst*, which is not a paradox: this CPU has SHA-NI, so CNG hashes
sha256 in hardware at 627 MB/s and the remaining time is spent reading — and reading from the file
cache does not parallelise. `md5` has no hardware path, saturates cores, and reaches **3.51×** —
the same ceiling every other CPU-bound measurement on this 12-logical / 6-physical box reaches.

So the pool did not change what parallelism is worth here; it changed what can be *offered* to it.
Hashing a tree is a bandwidth problem wearing a CPU problem's clothes.

## What the pool is actually worth — four arms, measured

The claim above ("the crossover fell from 26 ms to about 1 ms") is arithmetic from a 159 µs round
trip against a 26 ms spawn, and arithmetic is not a measurement. [`spike/crossover`](../spike/crossover/README.md)
measures it against the two things a competent person would write instead — a `child start` per
item, and a **static partition**: twelve children, each handed a contiguous slice. Predictions were
registered before the run; three held, one was half right, and **two were wrong**.

| per item | sequential | child per item | static chunks | pool (`pmap`) |
|---|---|---|---|---|
| 0.5 ms × 1600 | 1.00× | **0.04×** | **2.33×** | 1.64× |
| 2 ms × 500 | 1.00× | 0.17× | 2.48× | 2.46× |
| 8 ms × 150 | 1.00× | 0.54× | 2.64× | **2.65×** |
| 30 ms × 40 | 1.00× | 1.39× | 2.51× | 2.47× |

**Against spawn-per-item the claim holds, and by more than advertised** — 41× the throughput at
0.5 ms items, not "a bit better". **Against a static partition it buys no speed at all**: chunking
matches the pool everywhere, because it pays the start cost twelve times in total and then has no
protocol. On uniform work the per-item round trip earns nothing back.

**But every row above is a ~1-second job, and that turned out to matter.** The pool's wall clock
barely moved across the four sizes — 452, 374, 376, 379 ms — which is a fixed cost dominating, not
a ceiling. Holding the item at 8 ms and growing the *job*:

| sequential work | static chunks | pool |
|---|---|---|
| ~1 s | 2.28× | 2.07× |
| ~4 s | 2.93× | **3.14×** |
| ~16 s | 3.16× | 3.09× |
| ~32 s | 3.17× | **3.21×** |

The real ceiling is **~3.2×**, flat from 4 seconds of work onward, and a one-second job collects
only two thirds of it. **Startup is worth a few hundred milliseconds and is fully amortised by
about four seconds** — so a job under a second is not worth pooling, and above a few seconds the
partition's edge disappears entirely: 3.17× against 3.21× is the same number.

Where the queue earns its keep is **items whose cost you cannot predict**, and only when the
expensive ones *cluster*. Same 500 items, same total work, a tenth of them 10× the rest:

| | static chunks | pool |
|---|---|---|
| heavy items scattered at random | **2.30×** | 2.05× |
| heavy items contiguous (a sorted list, a directory of large files) | 1.50× | **2.18×** |

Scattered, the chunks self-average and a partition is fine — which is why the first version of this
test proved nothing. Clustered, the partition is bounded by its unluckiest child while the queue
simply hands the next item to whoever is free.

**And one correction to the number above it.** "Below roughly 25–30 ms per item, spawning costs
more than it saves" was written as a single-item statement, and the obvious objection is that
spawns overlap too, so the real crossover should be far lower. It is not: spawn-per-item stays
underwater until ~20–30 ms per item, exactly as first written. **Process creation does not
parallelise.** Serially one `cmd /c exit` costs 17.1 ms and one machteld child 44.5 ms; at width 12
that should be ~270 starts a second and it measures **~90**. Concurrency buys about 4× on spawning,
not 12×, so `spawn_cost / width` is the wrong model to reason with.

So the honest summary: the pool's value is **small items, unpredictable or clustered item costs,
supervision, and one call instead of thirty lines** — it matches a hand-written partition on speed
rather than beating it, and only trails on jobs too short to be worth parallelising. And for a
single external program per item it is the wrong tool outright:
`child start` spawns the real program directly, with no intermediate process, and wins 2.60×
against 2.34×. Full numbers and the prediction scoring in
[spike/crossover/RESULTS.md](../spike/crossover/RESULTS.md).

## What remains open

- ~~**`child` cannot feed a running child.**~~ **Closed.** This was the one thing missing, and
  `child start -channels` supplies it: the child's stdin, stdout and stderr become ordinary Tcl
  channels, so a running child can be fed and read for as long as it lives. Note what it did
  *not* need — a `child send` verb. Handing the pipes to Tcl gives `puts`, `gets`, `chan event`
  and every other channel command at once, where a verb would have re-implemented one of them.
- **Two machteld processes cannot share one store file.** `store open` fails outright with
  *database is locked*, because `CREATE TABLE IF NOT EXISTS` takes a write lock with no busy
  timeout. This is unrelated to queues — two instances of the same wrapped tool hit it — and is
  worth its own decision rather than riding along with a parallelism feature that was refused.
