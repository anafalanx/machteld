---
type: decision-record
title: Direction
description: Current product boundary and decision rules for Machteld 0.14.0.
tags: [machteld, direction, scope]
---

# Direction

The 0.14.0 product sentence is the decision filter:

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

Decided 2026-08-26 (the narrowed vision; plans 015/016 in the z estate):

- User capabilities are written in Tcl and Lua, and only those. When
  machteld itself requires more, the author provisions it in the box -
  vendored, pinned, gated - the way SQLite, Lua, and yyjson entered.
- External software is not extended into; it is COMMANDED: `run`,
  `child`, and `scope` keep any program on a supervised, job-caged,
  budget-killed leash. That is the answer to "other technologies", and
  it always was.
- The external-runtime lanes (Deno, Bun, Node, Go sidekicks, embedded
  Python) and the machinery superstructure around them were examined in
  full discourse and retired; the engine wire stays language-neutral as
  dormant contract, blessing no one.
- Engine confinement becomes GRADED (0.16.0): explicit start-time
  rights - read, write, env, open - deny-by-default, immutable per
  engine, visible in stats, conform-proven. The cage is
  accident-prevention for a trusted author's own components, never an
  adversarial sandbox, and the contract says exactly that.
- `spawn` and `net` as engine rights are refused pending their own
  rulings.

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
