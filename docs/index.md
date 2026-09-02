---
type: index
title: machteld documentation
description: The documentation map for the Machteld 0.15.1 runtime.
tags: [machteld, windows, tcl, runtime]
---

# machteld 0.15.1

machteld is a compact Windows machine-control runtime. A program is ordinary
Tcl 9 whose first executable command explicitly requires `machteld`; the runtime
adds a self-describing command palette and can package that program as one exe.
This release embeds the complete Tcl/Tk 9.0.4 reference alongside Machteld's
own exact command reference.

- [Overview](overview.md) - product boundary and a first program.
- [Complete Machteld reference](reference/machteld/index.md) - exact pages for
  every command and subcommand.
- [Agent bootstrap](reference/machteld/agent.md) - how to query the embedded
  Machteld, Tcl, and Tk corpus efficiently.
- [Palette](palette.md) - a compact composition-oriented command tour.
- [Contract](contract.md) - entry, values, errors, time, and handles.
- [Execution model](execution-model.md) - blocking work, evented work, and lifetime.
- [Parallel work](parallel.md) - `worker`, `pool`, and `pmap`.
- [Packaging](packaging.md) - direct entries and standalone tools.
- [External libraries](extensions.md) - Tcl extensions, precedence, and the deployment covenant.
- [The engine](engine.md) - the 0.15.1 engine contract: `macht`, the wire, the boundary, sidecar engines.
- [Architecture](architecture.md) - hosts, prelude, native core, and metadata.
- [Creed](creed.md) - the design tests.
- [Ecosystem policy](ecosystem-policy.md) - what may enter the executable.
- [Direction](direction.md) - current product decisions and non-goals.
- [Roadmap](roadmap.md) - built now and possible next work.

The executable and wrapped tools carry these guides plus complete Machteld,
Tcl 9, and Tk 9 references. Use `docs status` to establish exact versions and
corpus identity, `docs get` for exact IDs or sections, `docs search` for bounded
discovery, and `docs extract` when filesystem search is preferable. `help` is
the concise human-facing shorthand.
