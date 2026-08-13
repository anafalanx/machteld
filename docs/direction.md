---
type: decision-record
title: Direction
description: Current product boundary and decision rules for Machteld 0.10.1.
tags: [machteld, direction, scope]
---

# Direction

The 0.10.1 product sentence is the decision filter:

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
