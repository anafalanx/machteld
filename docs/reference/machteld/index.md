---
id: machteld/index
type: index
title: Machteld reference
summary: Entry point for the complete, version-matched Machteld command reference.
commands:
---

# Machteld reference

This is the authoritative command-by-command reference for the Machteld runtime
in this executable. Each command page states its complete public syntax, values,
errors, resource lifetime, constraints, and examples. Use `manifest` for a
structured inventory of the running API and the documentation interface for
exact lookup and search.

Every command lives in `::machteld` and is available unqualified at top level.
Nested namespaces should use the qualified name or add `::machteld` to their
namespace path.

## Command groups

- Process control: `run`, `child`, `wait`, `scope`, and `detach`.
- Interactive processes: `pty`.
- Filesystem and machine state: `dirs`, `links`, `canon`, `watch`, and `mtps`.
- Data and network: `http`, `json`, `csv`, `hash`, and `store`.
- Tool construction: `cli`, `log`, `worker`, `pool`, and `pmap`.
- Runtime and distribution: `version`, `manifest`, `docs`, `help`, and `wrap`.

The complete Tcl 9 and Tk 9 references are separate scopes in the embedded
reference pack. Search for an exact Tcl command such as `tcl/command/dict` when
the language itself, rather than the Machteld palette, is the subject. Upstream
`application` pages describe upstream `tclsh`/`wish`; Machteld entry and host
routes are defined only by this Machteld reference.
