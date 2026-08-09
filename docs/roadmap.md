---
type: roadmap
title: Roadmap
description: What's built (M0–M2 and the tool factory) and what's next.
tags: [machteld, roadmap, milestones]
timestamp: 2026-07-09
---

# Roadmap

## Built

- **M0 — the host.** Console starpack carved from sturm/els (`Tcl_Main`, Tk on demand, UTF-8, SQLite inside) — a tclsh-like single exe.
- **M1 — execution core.** `run` / `child` / `wait` / `scope` / `detach` in C over the winjob substrate: born-in-job launch, `KILL_ON_JOB_CLOSE` die-with-parent, whole-tree kill, resource caps, BatBadBut / CVE-2024-24576 mitigation, `EscapeArg` quoting; `-timeout` / `-mem` / `-cpu` / `-dir` / `-stdin` / `-env`, and `-onout` / `-onerr` live streaming. Adversarial invariants translated from drang and verified.
- **M2 — pty.** ConPTY `spawn` / `send` / `read` / `close` / `list`, the `expect` loop, and `vtstrip`. Verified on real hardware; host reap confirmed clean.
- **`store`** — statically-linked SQLite key-value.
- **The tool factory.** The shared-AppInit factoring, the GUI `WinMain` bare, both bares embedded in `machteld.exe`, and the self-contained [`wrap`](palette.md) verb — one self-contained tclkit. See [packaging](packaging.md).

## Next — 0.3.0, in order

Ratified 2026-08-08; the reasoning is in [direction](direction.md).

1. **The manifest** — the self-describing runtime dict ([creed](creed.md) 4 / [the contract](contract.md)), built *first* so every new verb declares itself into it rather than being retrofitted. Carries each verb's error codes too, which is how creed 5's closed registry gets its completeness test.
2. **`watch`** — live file events: handle + blocking read, waitable by the existing `wait`, coalesced by default with `-raw` available.
3. **The change-viewer** — ✅ built (`tool/changes`): a live list of paths as they change with a preview of the one you click, pure Tcl/Tk, `wrap`'d into its own 6.1 MB exe. Filters VCS and build churn (`--all` to see everything), describes binaries rather than dumping them, and carries `--selftest` so the tool tests its own model with no window — which matters because a hidden Tk window drops events and would be testing something else. **0.3.0 ships when it does.**

✅ **`watch info` / `pty info`** landed 2026-08-09. They arrived with a cockpit verb (`mt`) that
was **built, measured and removed the same day**: it refreshed 8×/second idle and not at all while
the session was blocked in `child wait` or `watch read`, which is what supervision is made of.
The two `info` subcommands stay because they closed a real asymmetry — `child` had `info`, the
other handle verbs returned bare tokens — and because non-destructive observation is the right
primitive with or without a window. See [direction](direction.md).

✅ **`ps`** and **`tasks`** landed 2026-08-09 — machine-wide process enumeration
(`ps list` / `info` / `kill ?-tree?`) and the task manager built on it (`tool/tasks`, wrapped to
`tasks.exe`). The tool was written, it named a capability machteld did not have — it
could supervise processes it *started* but could not see one it did not — and that capability was
built to fit. That was rule 5 as it then stood; the rule has since been rewritten so a domain no
longer has to be asked for before it may be built.

✅ **`json`** landed 2026-08-09 — hand-rolled C into `Tcl_Obj`, gated on the vendored nst/JSONTestSuite (95/95 `y_`, 188/188 `n_`). The signature-derived CLI and shapes remain, to land at the moment a tool reaches for them.

## The standard library

Assessed 2026-08-09 against Python, Go and Deno rather than against what happens to be built:
three categories are **empty** — crypto/hashing, CLI parsing, logging — and TLS is missing, so
`http` cannot reach an https URL. Process control, meanwhile, is already ahead of all three and
is the asymmetry to widen. The plan, its design rules and its ordering are in
[the standard library](stdlib.md).

✅ **Phase 0 done 2026-08-09** — the prelude now holds itself to the contract it lands in: every
error carries a code, and the manifest describes a Tcl verb as fully as a C one. Next is `hash`
(C, over CNG), then `cli`, then `log`.

## Later

- **Machine-control domains** — `reg`, `svc`, `evt`, then `net` / `host` / `user` / `wmi`. All wanted, none scheduled. A tool asking is still the best reason to build one, as it was for `watch` and `ps`, but since [rule 5](direction.md) was rewritten it is not the only one: building a domain to find out what its dict wants to be is now reason enough. Our own C; TWAPI a quarry for WMI/COM only ([ecosystem policy](ecosystem-policy.md)).
- **An object layer over TclOO** — deferred, not refused.
- **The chrome console** — a Tk cockpit. The read-only version was tried and removed: a window
  that only *observes* the session freezes during exactly the blocking calls it exists to show.
  The measurement says the viable shape is one that **owns the event loop** — you launch work from
  it, so nothing at the top level ever blocks. That is a launcher, not a monitor, and it is a
  bigger thing than what was built. Unscheduled.

## Settled

**The name is machteld** — ratified 2026-08-08, no longer provisional.

---

*machteld is built with the Go + Deno workbench; this product does not reopen that decision.*
