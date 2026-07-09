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

## Next

- **The first real tool** — a live "watch the agent change the codebase" viewer: a pure-Tcl/Tk tool `wrap`'d by machteld, pulling in a `watch` primitive (a general addition to the shared AppInit) when it needs live file events.
- **Machine-control domains** — `svc` (services), `reg` (registry); later `evt` / `net` / `wmi` / `host` / `user`. Our own C; TWAPI a quarry for WMI/COM only ([ecosystem policy](ecosystem-policy.md)).
- **The manifest** — the self-describing runtime dict ([creed](creed.md) principle 4 / [the contract](contract.md)).
- **The chrome console** — a Tk cockpit (fork tkcon: dark ttk, manifest-fed completion, a live child/event sidebar).
- **The final name** — *machteld* is provisional.

---

*machteld is built with the Go + Deno workbench; this product does not reopen that decision.*
