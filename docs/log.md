---
type: log
title: Change log
description: Update history for the machteld knowledge bundle and build.
tags: [machteld, log]
timestamp: 2026-07-09
---

# Log

## 2026-08-09 — `mt`: the session watching itself

The question was whether to ship GUI tools inside `machteld.exe`. Three positions were argued
and nine adversarial critics attacked them; every affirmative case died, mostly on dispatch
mechanics. The framing was wrong. **machteld already ships Tcl — the prelude — and a third of the
palette is already written in it** (`help`, `manifest`, `scope`, `version`, `vtstrip`, `wrap`).
The argument had been about packaging *programs* when the question was about shipping *code*.

And the tool worth shipping was neither of the ones being argued over. `manifest` says what
machteld can do; nothing said what it is *doing*.

- **`mt`** ([the palette](palette.md)) — a live window over the current session: children
  launched, terminals steered, directories watched, and processes started and deliberately let
  go. Each row joins machteld's own token to what `ps` knows about that pid, so `child#3` shows
  with its name, memory and CPU.
- **`watch info` and `pty info`** — additive subcommands the cockpit demanded. `child` had
  `info`; the other two handle verbs returned bare tokens, so a watch could not be attributed to
  a directory. Rule 5 again, and read-only.

### Why it is a verb and not an exe — architecture, not preference

`proc_ctx` is allocated **per interpreter** and passed to every command as its client data.
There is no global registry, no shared section, no file. A separate `monitor.exe` would
enumerate its *own* children, which is nothing, and could not see another machteld's tokens at
all. The tool has to run inside the session it reports on. That settled a question that had been
framed as taste: this one tool ships as Tcl because it cannot ship as anything else.

### Non-destructive by construction

The sharper constraint, and the reason `watch info` / `pty info` exist. `watch read` **drains**
the event queue; `pty read` **consumes** the child's output. A monitor built on either would
steal from the program it is monitoring — an observer that changes what it observes is worse than
no observer. `mt` calls neither, and the suite proves it: six snapshots leave `pending` at 2 and
16, and the owner can still read every event afterwards.

The **Detached** section is the one that earns its place. `detach` is fire-and-forget on purpose
and tracks nothing, so those processes are invisible to `child list` by design; `mt` finds them
through `ps` by parent pid. The distinction drawn is between what machteld *controls* and what
it is merely *responsible for*, and a monitor that quietly omitted them would be flattering
itself.

### Gates repaired, and one break-tested

- The **registry scan** read four hardcoded `.c` files and nothing else. It now globs `src/*.c`
  — so a new source is inside the gate on arrival rather than when someone remembers — **and**
  reads the prelude, because `mt` raises `{MACHTELD MT badvalue}` and creed 5 does not say "the
  errors written in C". One hole is left open and named in [the contract](contract.md) rather
  than hidden: `wrap` and `help` still raise 11 bare `return -code error` with no code at all.
  The suite prints that count every run.
- The **pty ensemble map** in the prelude is hand-maintained, and `pty info` existed in the
  binary while being uncallable because the map still had five entries. The count stayed at six
  either way — five core plus `expect` — so only a set comparison finds it. Break-tested: with
  the entry removed the manifest reports seven subcommands and the binary six, and the gate
  fails on its own.
- **The window tests were files nobody ran.** `tasks_ui.tcl` and now `mt_ui.tcl` are driven from
  the suite by glob, so a new `*_ui.tcl` is picked up without being remembered — the same fix as
  the tool selftests, for the same reason.

Measured: `mt.tcl` costs **1.3 ms** to parse at startup, and Tk stays unloaded until the window
is opened, so a machteld that never calls `mt` pays nothing for it.

## 2026-08-09 — `ps` and `tasks`: seeing processes we did not start

A task manager was asked for. Writing it named the gap immediately: machteld could **supervise**
processes it launched — born-in-job, tree-kill, caps — and could not **see** one it had not.
`child list` returns machteld's own tokens; there was no `CreateToolhelp32Snapshot`, no
`EnumProcesses`, nothing machine-wide anywhere in `src/`. So `ps` was built to fit the tool,
which is rule 5 running the right way round. (That rule was rewritten later the
same day — building on spec is now allowed — but this is still how `ps` arrived, and still the
version that produces the best-shaped dict.)

- **`ps`** ([the palette](palette.md)) — `list` / `info` / `kill ?-tree?`. A row carries
  `pid ppid name exe mem private cpu threads started access`. 257 processes in 11 ms; the
  numbers agree with `Get-Process` (63.937 s of CPU against its 63.97).
- **`cpu` is cumulative, not a percentage.** A rate needs two samples and a clock, so computing
  one inside the verb would mean hidden state and an answer that depended on when you last
  asked. The tool divides; the verb reports. Same reasoning as `watch`'s per-read coalescing.
- **Denied is not zero.** Without elevation about 150 of 257 processes refuse inspection. They
  stay in the listing — with their snapshot fields, `access 0`, and every unreadable field the
  **empty string**, never `0`. Failing the whole listing over a process you may not inspect
  would make the verb useless on exactly the machines it is for.
- **`tasks`** (`tool/tasks`, wrapped to `tasks.exe`, 6.1 MB) — flat sortable list, filter, live
  refresh, End Task and End Tree. Deliberately smaller than Windows' own: no grouping, no
  graphs, no services tab. Rows reconcile rather than rebuild, so a selection survives a refresh
  — which matters because the next button is End Task.

### Three gates were passing vacuously

Worth recording, because all three were *green* while the thing they check was absent.

- The **error-code registry** scan knew `mt_error(interp, DOMAIN, code)` and literal
  `Tcl_SetErrorCode`. `ps.c` names its domain once inside its own raiser and passes only the
  code — so the scan found nothing in it, and all four closure checks passed on an empty set.
  The manifest cross-check is what actually caught `PS` and `denied` going undocumented.
- The **palette-doc** check matched `*$v*`. A two-letter verb passes that on the strength of
  "steps", "helps" or "maps". Tightened to a whole-word match, it immediately found that
  `vtstrip` and `version` had never been documented either — `vtstrip` appeared only inside a
  comment, `version` only as the unrelated `store version`.
- The **manifest generator** attributed `-tree` to `info`, because `kill` was an implicit
  fallthrough with no `idx ==` marker for the branch scanner to see. Same failure as `watch
  read` last release.

A gate that can be silently emptied is worse than no gate. Each was repaired at the scanner
rather than at the symptom, and the registry gate was then broken on purpose to confirm it bites.

### And one real bug, found only by driving the window

`TerminateProcess` on a process that has **already exited** fails with `ERROR_ACCESS_DENIED` —
the same error a genuinely protected process gives. Read at face value, `ps kill` told the user
to re-run as administrator about a process that had simply finished, which in a task manager is
the likeliest case of all: you click End Task on the row that was already on its way out.
`ps_kill_one` now consults the exit code before reporting, and answers `notfound`.

The model selftest could not have found this; `test/tasks_ui.tcl` drives the real mapped window
— selection, sorting, reconciliation, and End Task through the button's own callback — and did.

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
