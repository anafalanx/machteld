---
type: spike
title: Channel-based worker pool
description: Does the persistent-worker design in docs/parallel.md survive contact? Built on stock Tcl, attacked deliberately, findings recorded.
tags: [machteld, parallel, spike]
timestamp: 2026-08-09
---

# Spike: a channel-based worker pool

**Question:** the design in [parallel](../../docs/parallel.md) says workers should be Tcl
channels rather than spawned-per-item processes. Before writing any C for it, is it *reliable*?

**Answer: yes — after two bugs, neither of which was where I was looking.**

```
machteld.exe spike/pool/spike.tcl
```

- `worker.tcl` — the far side: read a JSON line, dispatch, write a JSON line.
- `pool.tcl` — the pool: `open |cmd r+`, non-blocking channels, `chan event`, `vwait`.
- `spike.tcl` — eighteen checks, written to fail.

Everything runs on **stock Tcl**. No new C, no machteld verb is required for the transport, which
is what makes it a fair test: if it were fragile here it would be fragile with a job object
wrapped around it.

## What was attacked, and what happened

| hazard | expectation | result |
|---|---|---|
| 300 items through 8 workers | correct, no losses | ✅ all distinct, none lost |
| **a reply far larger than the pipe buffer** (1–4 MB) | *this is the one I expected to deadlock* | ✅ intact, no wedge |
| a worker spewing to an **unread stderr** | might fill and block | ✅ no effect |
| a worker **dying mid-item** | detect, requeue, do not loop | ✅ detected, requeued, poison-capped |
| errors crossing the process boundary | errorcode survives | ✅ `{MACHTELD SPIKE deliberate}` intact |
| payloads with newlines, quotes, unicode, empties | framing must not break | ✅ byte-for-byte round trip |
| orphans after close | none | ✅ none |
| ten consecutive pools | no flakiness | ✅ clean |

The pipe-buffer deadlock — the hazard named as *most likely to be subtly wrong on Windows* — did
not materialise. Non-blocking channels on both ends plus `chan event` handle a 4 MB reply through
a pipe that holds a few KB. That is the single most valuable thing this spike established,
because it was the risk that could have sunk the design.

## The two bugs, and why they matter beyond this spike

Both were **namespace resolution**, and both produced symptoms that pointed somewhere else
entirely.

**1. `json` is not a command inside `::pool`.** The prelude puts the palette on the *global*
namespace path, and Tcl does not consult the global path for a lookup that begins inside another
namespace. So every `Feed` threw, the `catch` around it read that as a dead worker, and the pool
spent its life killing and respawning perfectly healthy processes — **12 deaths and 8 requeues to
deliver 4 items**. Every visible symptom pointed at the pipe. The cause was name lookup.

This is documented in [the palette](../../docs/palette.md), and both shipped tools carry
`namespace path ::machteld` for exactly this reason. I walked into it anyway, which is the
argument for the line being in a template rather than in everyone's memory.

**2. `close` inside `::pool` resolved to `::pool::close`** — the pool's own destructor — so every
channel teardown silently called it with a channel as its token, and no channel was ever closed.
The fix is `chan close`, which cannot be shadowed. Note the tell: I had written `::close` with
the global qualifier in one place and bare `close` in another, so I knew about the hazard and
still got it wrong where it was not staring at me.

**The transferable lesson:** in a namespace, a bare command name is a guess. The palette needs
`namespace path`, and anything sharing a name with a Tcl built-in needs the ensemble form
(`chan close`) or a qualifier.

## What this does *not* prove

- **Supervision is untested here**, because stock Tcl has none. A worker opened with `open |...`
  is not in a job object: it cannot be tree-killed, does not die with its parent, takes no caps,
  and is invisible to `child list` and `scope`. That is the C work the design calls for, and this
  spike deliberately does not simulate it.
- **One item in flight per worker.** Pipelining several would be faster and would make the
  reply-to-item mapping a correlation rather than a fact. Not attempted.
- **No cancellation mid-run**, no timeout per item, no backpressure beyond the one-in-flight rule.
- **Windows only**, one machine, one Tcl version.
