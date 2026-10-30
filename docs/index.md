---
type: index
title: machteld documentation
description: The documentation map for machteld 22, in preparation.
tags: [machteld, windows, tcl, runtime]
---

# machteld 22

These pages describe machteld 22, in preparation: not yet released or signed.
The older signed release's own embedded reference and release notes
describe its behavior. Use the selected executable's
`manifest`, `docs status`, and (for incremental development builds)
`build-info.dict` to identify its capabilities; see [release history](roadmap.md).

machteld is a compact Windows runtime for Tcl/Tk 9 programs. It is strongest
at what tools do: supervised processes and terminals, files, HTTP, JSON,
hashing and SQLite, in one executable that installs nothing. A program is
ordinary Tcl 9 whose first executable command explicitly requires `machteld`;
the runtime adds a self-describing command palette and can package that
program as one exe.
The Machteld distribution embeds the complete Tcl/Tk 9.0.4 reference alongside
Machteld's own exact command reference.

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
- [Architecture](architecture.md) - hosts, prelude, native core, and metadata.
- [Native validation](native-validation.md) - analysis, stress/scaling evidence,
  and instrumentation gaps.
- [The els method](els-method.md) - one-exe Windows applications in C and
  Tcl/Tk 9, the method els and machteld were built with.
- [Creed](creed.md) - the design tests.
- [Ecosystem policy](ecosystem-policy.md) - what may enter the executable.
- [Direction](direction.md) - current product decisions and non-goals.
- [Roadmap](roadmap.md) - built now and possible next work.

The source checkout also contains a responsive project inspector
(`examples/project-inspector/README.md`) and an explicitly deployed external
extension (`examples/external-extension/README.md`).
These are examples, not additional built-in commands; their source and tests
are not part of the embedded reference corpus.

The distribution and tools wrapped with `--with-docs` carry these guides plus
complete Machteld, Tcl 9, and Tk 9 references. Use `docs status` to establish
exact versions and corpus identity, `docs get` for exact IDs or sections, `docs
search` for bounded discovery, and `docs extract` when filesystem search is
preferable. `help` is the concise human-facing shorthand. Default wrapped tools
omit this corpus; `docs schema` and `manifest` remain available, and bare `help`
explains how to obtain the reference.
