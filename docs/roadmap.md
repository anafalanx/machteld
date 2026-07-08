---
type: roadmap
title: Roadmap & open questions
description: Milestones M0–M4, and the design work not yet done.
tags: [machteld, roadmap, milestones, open]
timestamp: 2026-07-07
---

# Roadmap

- **M0** — carve the console host from sturm/els (`Tcl_Main`, Tk on demand, UTF-8 manifest, SQLite already inside) → a tclsh-like single exe.
- **M1** — `run` / `child` / `wait` / `scope` / `detach` in C, porting winjob's *semantics* and translating drang's adversarial tests (born-in-job, `KILL_ON_JOB_CLOSE`, BatBadBut / CVE-2024-24576, `EscapeArg`, handle-inheritance discipline).
- **M2** — `pty` (ConPTY expect).
- **M3** — `store` / `json` / `fs` / `svc` / `reg`, palette polish, a decent REPL, sign.
- **M4** — the chrome console (fork tkcon: dark ttk, completion fed by the manifest, a live `child`/event sidebar).

# Open — not yet designed

- Per-domain verb signatures in full (`svc` / `reg` / `store` / `fs` detail) — propose-and-refine, no big forks left.
- The **manifest schema** (the exact shape of the self-description dict — see [the contract](/contract.md)).
- The **final name** (working name *machteld* is provisional).

---

*machteld is built with the Go + Deno workbench; this product does not reopen that decision.*
