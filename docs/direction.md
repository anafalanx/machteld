---
type: decision-record
title: Direction
description: Current product boundary and decision rules for Machteld 0.21.
tags: [machteld, direction, scope]
---

# Direction

The 0.21 product sentence is the decision filter:

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

Version 0.20 establishes the product boundary by subtraction: the
compute-engine architecture, its wire, `macht`, Lua, LPeg, lua-cjson, and the
engine-bound column library were removed. They leave no compatibility command
or migration layer. The release adds no replacement capability; its clean
Tcl/Tk runtime is the baseline for subsequent development.

Standing architectural decisions:

- **Machteld is Tcl/Tk, with C/C++ underneath.** Tcl is the sole program,
  composition, and orchestration language; Tk is the graphical toolkit; C and
  C++ are the only admitted implementation languages for native facilities.
- When Machteld itself requires more, the implementation belongs in Tcl or in
  a narrow native palette command, vendored, pinned, bounded, and gated like
  SQLite and yyjson. A second embedded scripting language is not retained for
  hypothetical future use.
- A user may bring their own Tcl packages and DLLs in a folder beside a built
  tool, loaded by ordinary Tcl mechanics. Machteld does not package them, and
  such a tool is deliberately no longer a single file.
- External software is commanded through `run`, `child`, and `scope`. It is an
  ordinary supervised process, not a privileged extension architecture.
- Parallel work uses threads inside carefully bounded native commands or Tcl
  worker processes through `pmap`. New long-running native operations must
  provide cancellation points or an explicit bounded contract.

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

## Placement: Tcl or native

Where a new capability lives is decided by these questions, in order:

1. Can ordinary Tcl express it clearly and within the required bounds? Keep it
   in Tcl.
2. Is it graphical application structure or ordinary desktop UI? Use Tk and
   Tcl.
3. Does it require a Windows API, a bundled native library, or measured native
   performance? Expose the smallest useful Tcl-shaped command implemented in C
   or C++.
4. Is it an independently useful executable? Launch and supervise it with the
   existing process commands and define its data protocol in the program.
5. Can a native operation run indefinitely or block inside foreign code? Give
   it cancellation points or place the operation in an ordinary supervised
   process; do not make the host event loop hostage to it.
