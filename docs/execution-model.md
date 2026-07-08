---
type: convention
title: Execution model
description: Linear by default; explicit concurrency; and no handle ever outlives the tool.
tags: [machteld, execution, concurrency, lifetime, jobobject]
timestamp: 2026-07-07
---

# Execution model

**Linear by default.** Verbs block (with timeouts); code reads top-to-bottom, which is the most legible thing to a model and a human alike. Concurrency is *explicit*: `child start` returns a handle immediately, and `wait $a $b -any` multiplexes. Interactive control (`pty`) stays linear via **expect**. A callback/event layer exists but is optional — reserved for the live cockpit.

**Handle lifetime is bounded — no orphans is the law.** No handle ever outlives the tool process (a root Windows **Job Object** with `KILL_ON_JOB_CLOSE`). Within a session, a `scope { … }` block kills anything opened inside it at the closing brace; `detach` opts a handle out to survive as a daemon/service.

```tcl
set a [child start ping host-a]
set b [child start ping host-b]
wait $a $b                                 ;# block for both
scope { set s [child start db.exe]; run migrate.exe }   ;# s dies at the brace — guaranteed
detach [child start watchdog.exe]                        ;# opt out: survive the tool
```

This surfaces winjob's kill-on-close guarantee as *language law*: the anti-orphan promise no stock Windows tool offers. The verbs themselves are in [the palette](/palette.md).
