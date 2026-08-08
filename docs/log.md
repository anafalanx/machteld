---
type: log
title: Change log
description: Update history for the machteld knowledge bundle and build.
tags: [machteld, log]
timestamp: 2026-07-09
---

# Log

## 2026-08-08 — 0.3.0: the palette describes itself, watches files, and reaches a tool

The release rule was ratified before the work: **0.3.0 ships when a tool ships**, because a
toolkit earns its palette by reaching one. `changes` is that tool.

- **`manifest`** ([the contract](contract.md)) — one dict, no arguments, navigated with
  `dict get`, so no subcommand vocabulary is invented and none has to be frozen. Nothing in it
  is hand-maintained: the C half is derived from `src/*.c` at build time by
  `tools/genmanifest.tcl`, the Tcl half is read out of the live interpreter. It describes
  itself, and a wrapped tool carries it.
- **`watch`** ([the palette](palette.md)) — live directory events over `ReadDirectoryChangesW`.
  Handle plus blocking read, mirroring `child start` / `wait`, so the palette keeps one lifetime
  model and needs no event loop. Coalesced per read (no hidden timer, so the same reads give the
  same answer), `-raw` for the unmerged stream, and lost events reported in-band rather than
  silently dropped.
- **`wait` became the one multiplexer.** It was child-typed throughout; it now resolves any
  token through a small seam, so `wait -any $child $watch` blocks on both and names the winner
  with no polling. What "ready" means stays the handle kind's business.
- **`changes`** (`tool/changes`) — the first real tool: what is changing in a tree on the left,
  the contents of the one you click on the right. Pure Tcl/Tk, stamped by `wrap` into its own
  6.1 MB exe, and built by the build so `wrap` is proven against the artefact being released.

**Errors became a contract rather than a promise.** The domain is now the verb you called —
`pty` raises `MACHTELD PTY`, not `MACHTELD RUN` — and the codes are a closed registry in
[the contract](contract.md) that a test holds to the C in both directions. Two defects fell out
of writing it down: an unresolvable program answered `launch` from `run`/`child`/`pty` and
`notfound` from `detach` (same condition, two codes, and the docs published the wrong one), and
`store` set no error code at all. Both fixed; `nohandle` now names the genuinely different
failure that used to share `notfound`.

Also: Tcl/Tk pinned at **9.0.4**; the name **machteld** ratified, no longer provisional; the
surface frozen and additive-only, with the one hole in that promise (prefix-matched subcommands)
recorded in [direction](direction.md) rather than papered over. The rules this stretch runs by
are in [direction](direction.md).

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
