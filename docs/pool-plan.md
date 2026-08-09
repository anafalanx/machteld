---
type: plan
title: The worker pool — step by step
description: How persistent workers land in machteld, what they must align with, and what previous work has to change.
tags: [machteld, parallel, pool, plan]
timestamp: 2026-08-09
---

# The worker pool — step by step

The design is in [parallelism](parallel.md); the spike that attacked it is in
[`spike/pool`](../spike/pool/README.md), clean over three runs. This is the order to build it in,
what each step must prove before the next begins, and — the part worth reading first — **what
already-shipped work has to change to make room for it**.

## What has already been proved, and what has not

**Proved** (measured, on this machine):

- Tcl's own `open |cmd r+` gives a live worker at **159 µs per round trip** against 26,000 µs to
  spawn one — the whole reason for doing this.
- A pool driven by `chan event` and `vwait`, no polling: **3.23× on 12 workers** for 13 ms items,
  which is *below* the spawn crossover and therefore work `child start` cannot parallelise at all.
- The hazard flagged as most likely to sink it — **deadlock by pipe buffer** — does not occur.
  4 MB replies survive a pipe that holds a few KB.
- Worker death mid-item, poison items, errorcodes crossing the boundary, payloads containing
  newlines and unicode: all handled.
- **A wrapped tool can spawn itself as a worker.** `[info nameofexecutable] --worker`, with the
  worker code inside the stamped exe and the full palette available to it. This was the riskiest
  assumption and it holds, which is what makes the whole thing viable for the tools machteld
  exists to stamp.

**Not proved, and deliberately so:** supervision. Everything above ran on stock Tcl, where a
worker is *not* in a job object — it cannot be tree-killed, does not die with its parent, takes no
caps, and is invisible to `child list` and `scope`. Supplying exactly that is the one piece of C
in this plan.

## Alignment — what previous work must change

Taken first, because it decides the shape of everything after.

**1. `execution-model.md` is stale and must be re-pointed.** It currently says: *"A callback/event
layer exists but is optional — reserved for the live cockpit."* The cockpit was built, measured
and removed earlier today. The event layer is now for **the pool**, and the sentence has to say
so rather than pointing at something that no longer exists.

**2. There will be two ways to wait, and that must be named rather than hidden.** `wait -any`
blocks on process handles; `chan event` waits on data through the event loop. [Creed](creed.md) 6
asks for one way to do each thing, so the split needs an explicit rule: **blocking verbs for
linear scripts, the event loop for pools and anything with a window.** They wait for different
events — process exit versus data arrival — and `child wait` demonstrably does not pump the event
loop, which is what killed the cockpit. Documented, not eliminated.

**3. The result dict must not fork.** `child_dict` is shared by `run` and `child wait`, and the
manifest derives `returns` from it. A channel-mode child therefore returns **the same shape** with
`out` and `err` empty; the channels are reached through `child info`, which is additive. Two
result shapes behind one verb would break the contract to save one field.

**4. The namespace trap needs to be louder than a paragraph.** The spike lost an hour to `json`
not resolving inside `namespace eval ::pool`, and again to `close` resolving to the pool's own
destructor — with every symptom pointing at the pipe. This is documented in
[the palette](palette.md), both shipped tools carry the line, and I walked into it anyway. The
`worker` and `pool` templates must carry `namespace path ::machteld`, and anything sharing a name
with a Tcl built-in must use the ensemble form (`chan close`).

**Resolved in step 5**, once there was something real to point them at:

1. [Execution model](execution-model.md) now points the callback layer at `pool` and at Tk, where
   it actually went.
2. The two ways to wait are a **table** in that document — blocking verbs wait for a *process*,
   the event loop waits for *data*, neither subsumes the other, and a blocking verb does not pump
   the event loop. Named, not hidden.
3. Held: a channel-mode child returns the same six keys as any other, verified rather than
   assumed.
4. Superseded by a better fix than the one written here. Rather than telling authors to declare a
   namespace path, `worker on` now compiles a handler **in the namespace where it was written**,
   so a handler calls its own file's procs by bare name like every other line around it. The
   prescription below would have left the trap in place and asked people to remember; this removes
   it for the case that bit. What is left is one ordinary rule — a namespace of your own needs
   `namespace path ::machteld` — plus a gate asserting **every palette verb is reachable by its
   bare name**, so a future verb called `close` or `format` fails the suite instead of being
   silently answered by Tcl's command of that name.

## The steps

Each step ends in a state that builds, passes the suite, and is worth committing. No step depends
on a later one.

### Step 1 — `child start -channels` (C, `src/proc.c`)

The only new C. A child launched this way keeps its stdin write end open, does **not** start the
capture reader threads, and exposes its pipes as Tcl channels through `Tcl_MakeFileChannel`.

- `child info $tok` gains `stdin`, `stdout`, `stderr` — channel names, absent in normal mode.
- `child wait $tok` returns the unchanged dict, `out`/`err` empty.
- `child close $tok` closes the channels; the handle must not be closed twice, once by Tcl and
  once by `child_free`.

**Gates before moving on** — these are the whole point of doing it in C rather than leaving it in
stock Tcl, so each is a test:

- a channel-mode child is still **tree-killed** by `child kill`
- `-timeout` still kills one that ignores its input
- `-mem` still caps one that allocates
- it still **dies with the parent** (`KILL_ON_JOB_CLOSE`)
- `scope` still reaps it at the closing brace
- it appears in `child list`
- no handle leak across a thousand start/close cycles

### Step 2 — `worker` (Tcl, prelude)

The far side, so any machteld or stamped tool can *be* a worker.

```tcl
worker on hash {path} { hash file sha256 $path }
worker serve                 ;# read a line, dispatch, write a line, until EOF
```

Handlers live in procs (top-level code runs 3.6× slower). A handler that raises is caught and
returned as `{ok 0 code {...} msg ...}`, so the error contract survives the boundary. Framing is
one JSON object per line — `json encode` escapes newlines, so a record can never split its own
frame, which is what makes `gets` a safe frame reader.

### Step 3 — `pool` (Tcl, prelude)

The director, over Step 1's channels rather than raw `open |...`, so every worker is supervised.

```tcl
set p [pool create -width 8 -- $exe --worker]
pool submit $p $items
pool wait   $p -timeout 60s     ;# -> results
pool info   $p                  ;# width, pending, inflight, done, dead, requeued
pool close  $p
```

Token `pool#N`, matching `child#N` / `pty#N` / `watch#N` / `hash#N`. One item in flight per
worker: with a single outstanding request the mapping from reply to item is a fact rather than a
correlation, and a dead worker has exactly one item to requeue.

The spike's eighteen adversarial checks come across as the acceptance test, unchanged in
substance — they already encode the hazards.

### Step 4 — `pmap` (Tcl, prelude)

The sugar, as a coroutine, so a Tk tool stays responsive while it runs.

```tcl
set results [pmap $items -width 8 -- $exe --worker hash]
```

**A constraint worth stating rather than discovering:** `pmap` names an *operation the worker
registered*; it cannot take a script block. A closure cannot cross a process boundary, and
shipping arbitrary script text per item would defeat bytecode caching and hand every worker an
`eval`. Workers are configured once, then fed data.

### Step 5 — realign the previous work

The four items above, now that there is something real to point them at.

### Step 6 — prove it end to end

Two things, because the acceptance tests only prove the mechanism:

- **A wrapped tool using a pool**, spawning itself — the arrangement already shown to work.
- **A realistic win**: hash a large tree in parallel against sequentially, and record the numbers
  in [parallelism](parallel.md) beside the rest.

✅ **Done.** [`sums`](../tool/sums/main.tcl) — a wrapped console exe that hashes a tree with copies
of itself, carrying a selftest that passes both wrapped and as a script, and asserting the claim
worth asserting: the pool's digests equal the ones the director computes alone, with no children
left behind after a run that raised.

The win is real but modest, and the honest version is recorded rather than the flattering one:
**1.27×** over this project's own tree of 45 KB files, **0.38×** at width 1, and **2.34×–3.51×**
on a gigabyte depending on the digest — ordered *inversely* to how fast the digest is, because a
hardware-accelerated sha256 leaves reading as the remaining cost and reading does not parallelise.
The first attempt at this measurement reported 38× and was wrong for an instructive reason; see
[parallelism](parallel.md).

## Risks, in the order I expect them to bite

1. **Handle ownership in Step 1.** Tcl closing a channel and `child_free` closing the same handle
   is a double-close, and on Windows that is a crash rather than an error.
2. **Non-blocking pipe edge cases.** The spike says the common paths are sound, but it exercised
   stock Tcl's pipe driver; a hand-made `Tcl_MakeFileChannel` may not behave identically.
3. **Capture versus channels** must be genuinely exclusive, and the manifest must say which
   options combine with which.
4. **Scale.** The spike ran tens of workers and thousands of items, not hundreds of thousands.

## What this plan does not do

No cancellation of an individual in-flight item, no pipelining of more than one item per worker,
no cross-machine anything, and no durable ledger — the append-only log stays where
[parallelism](parallel.md) left it, as an option for work that must outlive its director rather
than part of the transport.
