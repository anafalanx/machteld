---
type: decision-record
title: Direction
description: Current product boundary and decision rules for Machteld 0.15.1.
tags: [machteld, direction, scope]
---

# Direction

The 0.15.1 product sentence is the decision filter:

> machteld is a compact Windows machine-control runtime.

It runs explicitly opted-in Tcl programs, exposes a small native/Tcl palette,
and packages those programs without changing their API. A proposed feature must
improve that runtime directly; knowing one environment's layout, inventory,
policy, or command names is not runtime work.

Current decisions:

- A direct program file beginning with parsed `package require machteld` is the
  only general program entry; `.tcl` is conventional, not required.
- `wrap` is subordinate deployment machinery and accepts the same opt-in.
- Every full or wrapped host exposes one Machteld version and the same
  machine-control/data API, including static SQLite `store`, plus the complete
  exact-version reference corpus. Nested wrapping remains distribution-only.
- Documentation is a runtime interface: offline, versioned, machine-readable,
  provenance-bearing, and equally discoverable by people and agents.
- Native and Tcl manifest facts are explicit metadata, never inferred from
  implementation bodies.
- Linear blocking operations remain the default; concurrency is explicit and
  bounded by Job Objects, handles, deadlines, and lexical scope.
- Environment-specific project selection, command catalogues/resolvers,
  activity recording, and directory caching live outside this runtime.
  Launching still supports Machteld's deterministic `PATH`-only lookup for a
  bare command.

Decided for 0.12.0 (contract: [the engine](engine.md)):

- Heavy computation is out of process. The control plane is Tcl and only
  Tcl; foreign code enters as machinery - Lua kernels run by an engine the
  program starts, feeds, questions, and kills. No Lua runs in the host.
- The engine is the executable itself in engine mode, so every host and every
  wrapped tool carries its engine and nothing is installed; the wire is
  language-neutral so that a sidecar executable in the folder may be an
  engine under the deployment covenant.
- Computation runs where the data lives; a payload never passes through the
  control plane. The engine is a cache, never the truth.
- The machine is proven by build gates; kernels are trusted as written. There
  is no translation of expressions into Lua, no runtime oracle, and no
  sampling: a computation runs in Tcl or in Lua, never both.
- The engine is additive. Nothing leaves the Tcl side; a program that never
  calls `macht` starts nothing.

Decided 2026-08-26/29 (the narrowed vision, then the merge; plans
015/016 in the z estate):

- **A program is written in X or in ordinary Tcl.** X is a statically
  typed language compiled to Tcl by a compiler written in Tcl; both
  forms are first-class, and `wrap` turns either into an executable.
- When machteld itself requires more, **the author provisions it in
  the box** - fast C in the palette, or Tcl in the prelude - vendored,
  pinned, gated, the way SQLite and yyjson entered. There is no inline
  C in user programs.
- **A user may bring their own Tcl packages and DLLs in a side-folder**
  beside a built tool, loaded by ordinary Tcl mechanics. machteld does
  not package them, and such a tool is deliberately no longer a single
  file. (This retracts the 2026-08-24 decision to remove `load`.)
- External software is not extended into; it is COMMANDED: `run`,
  `child`, and `scope` keep any program on a supervised, job-caged,
  budget-killed leash. That is the answer to "other technologies", and
  it always was.
- The external-runtime lanes (Deno, Bun, Node, Go sidekicks, embedded
  Python) and the machinery superstructure around them were examined in
  full discourse and retired.
- **The engine and Lua retire**; the data plane comes in-process as a
  palette organ. Parallelism is threads inside C palette verbs plus
  child processes for tasks, with `pmap` the single language surface,
  and the law that no palette verb performs unbounded work without a
  cancellation point.

Admission questions, in order:

1. Is this a Windows machine-control primitive or a composition needed by many
   Machteld programs?
2. Can ordinary Tcl already express it clearly and safely?
3. Does it preserve deterministic values, structured errors, and bounded life?
4. Can its runtime behavior be included identically in direct, console-wrapped,
   and GUI-wrapped hosts?
5. Can the exact surface be stated in `manifest` without inference?

A "no" does not mean the idea is bad; it means the idea belongs in a program or
another project rather than in the runtime.

## Placement: host or engine

Where a new capability lives is decided by these questions, in order -
the first hit decides:

1. **Machine interaction or control** (processes, UI, network,
   lifecycle)? The host, always: the control plane is Tcl and only
   Tcl; the engine never owns control flow.
2. **Operates on engine-resident data** (pools, handles, columns)?
   The engine, always: computation runs where the data lives; a
   payload never passes through the control plane.
3. **Can it run away** (CPU-bound, unbounded, stuck inside one C
   call)? The engine: only the engine is budget-killable mid-flight,
   and only engine death is cheap - it is a cache, never the truth.
4. **Should its use be confinable** (grantable or deniable by an
   author)? The engine, under the graded rights: the host acts with
   the program's full authority by design.
5. **A pure helper both planes need?** Check whether Tcl already
   covers the host side (it often does); mirror into the cell only on
   demonstrated kernel need, with independent contracts and no
   fidelity promise between the twins - the json/cjson precedent.
6. **Tiebreaker - the wire toll**: small values with host-side data
   stay in the host; data already engine-side keeps its work
   engine-side.
