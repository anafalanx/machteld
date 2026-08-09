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

✅ **`mt`** landed 2026-08-09 — the cockpit: a live view of what the current session is
controlling, plus the `watch info` / `pty info` it needed. It ships as a **palette verb, not a
wrapped exe**, because handle state is per-interpreter: a separate monitor would enumerate its
own children, which is nothing. This also retires the "chrome console" idea's vaguest form —
what was wanted was not a nicer tkcon but a window that answers "what is this session doing".

✅ **`ps`** and **`tasks`** landed 2026-08-09 — machine-wide process enumeration
(`ps list` / `info` / `kill ?-tree?`) and the task manager built on it (`tool/tasks`, wrapped to
`tasks.exe`). This is rule 5 working as intended: the tool was written, it named a capability
machteld did not have — it could supervise processes it *started* but could not see one it did
not — and that capability was built to fit.

✅ **`json`** landed 2026-08-09 — hand-rolled C into `Tcl_Obj`, gated on the vendored nst/JSONTestSuite (95/95 `y_`, 188/188 `n_`). The signature-derived CLI and shapes remain, to land at the moment a tool reaches for them.

## Later

- **Machine-control domains** — `reg`, `svc`, `evt`, then `net` / `host` / `user` / `wmi`. All wanted, none scheduled: each is built when a tool reaches for it, as `watch` and `ps` were. Our own C; TWAPI a quarry for WMI/COM only ([ecosystem policy](ecosystem-policy.md)).
- **An object layer over TclOO** — deferred, not refused.
- **The chrome console** — partly answered by [`mt`](palette.md), which is the live child/event
  sidebar as its own window. What remains is the *interactive* half: a REPL with manifest-fed
  completion. Deferred until `mt` has been used enough to say whether steering from it is
  actually wanted — `mt` is read-only on purpose, and making it a launcher is a decision that
  should follow use rather than precede it.

## Settled

**The name is machteld** — ratified 2026-08-08, no longer provisional.

---

*machteld is built with the Go + Deno workbench; this product does not reopen that decision.*
