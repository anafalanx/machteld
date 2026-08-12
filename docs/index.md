---
type: index
title: machteld documentation
description: The documentation map for the Machteld 0.4.0 runtime.
tags: [machteld, windows, tcl, runtime]
---

# machteld 0.4.0

machteld is a compact Windows machine-control runtime. A program is ordinary
Tcl 9 whose first executable command explicitly requires `machteld`; the runtime
adds a self-describing command palette and can package that program as one exe.

- [Overview](overview.md) - product boundary and a first program.
- [Palette](palette.md) - the public command reference.
- [Contract](contract.md) - entry, values, errors, time, and handles.
- [Execution model](execution-model.md) - blocking work, evented work, and lifetime.
- [Parallel work](parallel.md) - `worker`, `pool`, and `pmap`.
- [Packaging](packaging.md) - direct entries and standalone tools.
- [Architecture](architecture.md) - hosts, prelude, native core, and metadata.
- [Creed](creed.md) - the design tests.
- [Ecosystem policy](ecosystem-policy.md) - what may enter the executable.
- [Direction](direction.md) - current product decisions and non-goals.
- [Roadmap](roadmap.md) - built now and possible next work.

The packaged executable carries these files. At runtime, `help` lists topics,
`help palette` returns one topic, and `help all` returns the bundle.
