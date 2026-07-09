---
type: log
title: Change log
description: Update history for the machteld knowledge bundle and build.
tags: [machteld, log]
timestamp: 2026-07-09
---

# Log

## 2026-07-09 — Built: M0–M2 + the tool factory

The design became code. Landed since the initial bundle:

- **M0** the console starpack host; **M1** the execution core (`run` / `child` / `wait` / `scope` / `detach`) over winjob, with the adversarial invariants (born-in-job, tree-kill, die-with-parent, CVE-2024-24576, quoting) verified; **M2** the ConPTY `pty` + `expect` + `vtstrip`, verified on real hardware.
- `run` polish: `-stdin`, `-env`, `-onout` / `-onerr` streaming, exe-resolution hardening.
- `store` (statically-linked SQLite).
- The **tool factory**: the shared `Machteld_RegisterLibs` AppInit, the GUI `WinMain` bare (the proper no-console host — not a PE byte-flip), both bares embedded in `machteld.exe`, and the self-contained [`wrap`](palette.md) verb.

Docs reconciled with the code: [index](index.md), [overview](overview.md), [architecture](architecture.md), [packaging](packaging.md) (new), [palette](palette.md) (built vs deferred), [roadmap](roadmap.md).

## 2026-07-07 — Initial design

Full architecture and v1 scope specified in one design session and captured as this bundle:
identity and posture, the [creed](creed.md), the everything-is-a-dict [contract](contract.md),
the linear [execution model](execution-model.md) with bounded handle lifetime, the surface
conventions and the hybrid [palette](palette.md), the vendor-and-freeze [ecosystem policy](ecosystem-policy.md),
and [milestones](roadmap.md). Working name: machteld (provisional). No code yet.
