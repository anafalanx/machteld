---
type: convention
title: Execution model
description: Linear by default; explicit concurrency; and no handle ever outlives the tool.
tags: [machteld, execution, concurrency, lifetime, jobobject]
timestamp: 2026-07-07
---

# Execution model

**Linear by default.** Verbs block (with timeouts); code reads top-to-bottom, which is the most legible thing to a model and a human alike. Concurrency is *explicit*: `child start` returns a handle immediately, and `wait $a $b -any` multiplexes. Interactive control (`pty`) stays linear via **expect**. A callback/event layer exists but is optional — it is what [`pool`](palette.md) is built on, and what a Tk tool uses to stay responsive.

**There are two ways to wait, and which one you are in is not a preference.** [Creed](creed.md) 6 asks for one way to do each thing, so the split is stated rather than left to be discovered:

| | waits for | use it for |
|---|---|---|
| **blocking verbs** — `wait`, `child wait`, `watch read`, `run` | a **process** to exit, or a timeout | linear scripts: the default, and what every example here shows |
| **the event loop** — `chan event` + `vwait` | **data** to arrive on a channel | `pool` and `pmap`; any tool with a window |

They wait on different events, so neither subsumes the other, and a blocking verb **does not pump the event loop** — `child wait` and a blocking `watch read` both stall `chan event` callbacks and freeze a Tk window until they return. Mixing the two is what makes a GUI hang, and it is why a pool multiplexes with `chan event` instead of waiting on its workers, and why a Tk tool polls with a short `-timeout` from an `after` handler rather than blocking its UI thread.

**Handle lifetime is bounded — no orphans is the law.** No handle ever outlives the tool process (a root Windows **Job Object** with `KILL_ON_JOB_CLOSE`). Within a session, a `scope { … }` block kills any children born inside it at the closing brace; `detach -- cmd` launches a daemon that deliberately survives the tool.

```tcl
set a [child start ping host-a]
set b [child start ping host-b]
wait $a $b                                 ;# block for both
scope { child start db.exe; run migrate.exe }   ;# the db child dies at the brace — guaranteed
detach -- watchdog.exe                          ;# opt out: a fresh daemon that survives the tool
```

This surfaces winjob's kill-on-close guarantee as *language law*: the anti-orphan promise no stock Windows tool offers. The verbs themselves are in [the palette](palette.md).
