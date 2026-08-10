---
type: roadmap
title: Roadmap
description: What's built (M0–M2, the front door and its journal) and what's next.
tags: [machteld, roadmap, milestones]
timestamp: 2026-07-09
---

# Roadmap

## Built

- **M0 — the host.** Console starpack carved from sturm/els (`Tcl_Main`, Tk on demand, UTF-8, SQLite inside) — a tclsh-like single exe.
- **M1 — execution core.** `run` / `child` / `wait` / `scope` / `detach` in C over the winjob substrate: born-in-job launch, `KILL_ON_JOB_CLOSE` die-with-parent, whole-tree kill, resource caps, BatBadBut / CVE-2024-24576 mitigation, `EscapeArg` quoting; `-timeout` / `-mem` / `-cpu` / `-dir` / `-stdin` / `-env`, and `-onout` / `-onerr` live streaming. Adversarial invariants translated from drang and verified.
- **M2 — pty.** ConPTY `spawn` / `send` / `read` / `close` / `list`, the `expect` loop, and `vtstrip`. Verified on real hardware; host reap confirmed clean.
- **`store`** — statically-linked SQLite key-value.
- **The tool factory — built, then retired 2026-08-10.** The shared-AppInit factoring, the GUI `WinMain` bare, both bares embedded in `machteld.exe`, and the self-contained `wrap` verb: one self-contained tclkit that stamped a Tcl/Tk directory into a standalone exe with no compiler. It worked. It went when machteld became a front door rather than a thing that makes exes — 4.7 MB of embedded bares and five 5.9 MB artefacts, to ship five files of Tcl. The tools ride inside the one exe now and `mt sums .` runs one. 10.2 MB → 6.0 MB. See [packaging](packaging.md).
- **The front door.** `front which` / `env` / `tools` / `run` / `journal`, the argv dispatcher (`mt rg -n TODO .`), and a SQLite [journal](journal.md) of every process it starts. Resolution is builtin verb, then shipped tool, then curated tool — and there is no system-`PATH` fallback. See [the plan](front-door.md).

## Next — 0.3.0, in order

Ratified 2026-08-08; the reasoning is in [direction](direction.md).

1. **The manifest** — the self-describing runtime dict ([creed](creed.md) 4 / [the contract](contract.md)), built *first* so every new verb declares itself into it rather than being retrofitted. Carries each verb's error codes too, which is how creed 5's closed registry gets its completeness test.
2. **`watch`** — live file events: handle + blocking read, waitable by the existing `wait`, coalesced by default with `-raw` available.
3. **The change-viewer** — ✅ built (`tool/changes`): a live list of paths as they change with a preview of the one you click, pure Tcl/Tk, at the time `wrap`'d into its own 6.1 MB exe and now shipped inside `mt.exe`. Filters VCS and build churn (`--all` to see everything), describes binaries rather than dumping them, and carries `--selftest` so the tool tests its own model with no window — which matters because a hidden Tk window drops events and would be testing something else. **0.3.0 ships when it does.**

✅ **`watch info` / `pty info`** landed 2026-08-09. They arrived with a cockpit verb (`mt`) that
was **built, measured and removed the same day**: it refreshed 8×/second idle and not at all while
the session was blocked in `child wait` or `watch read`, which is what supervision is made of.
The two `info` subcommands stay because they closed a real asymmetry — `child` had `info`, the
other handle verbs returned bare tokens — and because non-destructive observation is the right
primitive with or without a window. See [direction](direction.md).

✅ **`mtps`** and **`tasks`** landed 2026-08-09 — machine-wide process enumeration
(`mtps list` / `info` / `kill ?-tree?`) and the task manager built on it (`tool/tasks`, then wrapped to
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
error carries a code, and the manifest describes a Tcl verb as fully as a C one. ✅ **`hash` done 2026-08-09** — `md5 sha1 sha256 sha384 sha512`, HMAC, streamed file digests and
a cryptographic RNG, over CNG with nothing vendored. ✅ **`cli` done 2026-08-09** — declarative argument parsing, pure (it prints nothing and never
exits, because a wrapped GUI exe has no standard channels). `tasks` now runs on it and gained
`--help`. ✅ **`log` done 2026-08-09** — levelled, structured, and it never throws on a write failure.

**Phase 1 is complete**: all three empty categories are filled. Next is Phase 2 — `fetch` over
WinHTTP (so `http` can finally reach an https URL), then `csv`.

## Parallelism

✅ **The worker pool landed 2026-08-09**, in six steps against
[the plan](pool-plan.md): `child start -channels` (the only new C — a child's pipes become Tcl
channels, and its handles are still in a job object), `worker` (the far side: a handler is a proc,
its argument list is the request schema), `pool` (supervision — requeue on death, poison after
`-maxtries`, and results in submission order), `pmap` (the whole thing in one call, closing the
pool on every path and re-raising a worker's failure with the worker's own errorcode), the
realignment of what the pool made stale, and `sums` as the end-to-end proof.

The crossover for offering work to another process fell from **26 ms to about 1 ms** — measured
afterwards against the alternatives, where it holds against a `child start` per item (**41×** the
throughput at 0.5 ms items) and buys **nothing** against a hand-written static partition, which it
merely matches (3.21× against 3.17× on a 32-second job). What the pool is actually worth is small
items, item costs that are unpredictable or arrive clustered, supervision, and one call instead of
thirty lines. Two further numbers worth carrying: the ceiling on this box is **~3.2×**, and pool
startup costs a few hundred milliseconds that are amortised by about **four seconds** of work —
below a second, do not bother. The numbers, and the predictions that came out wrong, are in
[parallelism](parallel.md).

✅ **`sums`** (`tool/sums`, then wrapped to `sums.exe`) — the third shipped tool and the first that is
not a window: it hashes a tree using **copies of itself** as workers. One artefact, no tclsh, no
worker script on disk.

## Later

- **Machine-control domains** — `reg`, `svc`, `evt`, then `net` / `host` / `user` / `wmi`. All wanted, none scheduled. A tool asking is still the best reason to build one, as it was for `watch` and `mtps`, but since [rule 5](direction.md) was rewritten it is not the only one: building a domain to find out what its dict wants to be is now reason enough. Our own C; TWAPI a quarry for WMI/COM only ([ecosystem policy](ecosystem-policy.md)).
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
