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

This tree reports runtime version 30, in preparation and not yet released.
Match these pages to the executable's corpus and artifact identity, not merely
its package version: builds can change without a new version number.
Conceptual guides state design intent and history separately from the
implemented command pages.

Every command lives in `::machteld`. At top level, use the short names below
and the qualified name `::machteld::clipboard`. Tk supplies the global
`clipboard` command when loaded. Nested namespaces can use fully qualified
names or add `::machteld::palette` to their namespace path for the short names.

## Command groups

- Process control: `run`, `child`, `wait`, `scope`, and `detach`.
- Interactive processes: `pty`.
- Windows desktop: `child present` shows the state of a supervised application
  window. `desktop windows` lists open application windows and `desktop activate`
  requests foreground for a selected window. `desktop open` dispatches a local
  document to its associated viewer. `desktop apps` lists Start-menu shortcuts
  and Store applications. `desktop launch` opens a selected application, and
  `desktop icon` copies its icon into a Tk photo. `::machteld::clipboard owned` checks whether
  this process owns the clipboard.
- Filesystem and machine state: `dirs`, `links`, `canon`, `watch`, `mtps`, `lock`, and `publish`.
- Data and network: `http`, `json`, `hash`, and `store`.
- Tool construction: `cli`, `log`, `worker`, `pool`, and `pmap`.
- Runtime and distribution: `app`, `version`, `manifest`, `docs` and `help`.

For text-file bytes, `package require machteld::encoding 1.0` exposes
`::machteld::encoding::detect $bytes`. Supply a bytearray, such as the
result of `read` on a binary channel. The dictionary contains `status`,
`encoding`, `confidence` and `samplebytes`. A `match` supplies an ICU
encoding label and its estimate from 1 to 100. Empty or printable ASCII
samples can have many source encodings and return `nomatch`. Other samples
for which the detector finds no match also return `nomatch`. When Windows
does not provide the required ICU entry points, detection returns
`unavailable`. Both results carry an empty label and zero confidence.
The detector examines up to the first 1 MiB and preserves the supplied bytes.
Applications choose their confidence threshold and Tcl decoder.

The complete Tcl 9 and Tk 9 references are separate scopes in the embedded
reference pack. Search for an exact Tcl command such as `tcl/command/dict` when
the language itself, rather than the Machteld palette, is the subject. Upstream
`application` pages describe upstream `tclsh`/`wish`; Machteld entry and host
routes are defined only by this Machteld reference.

The shared runtime carries the reference. Programs can use it from either a
direct entry file or an archive.

Machteld executes trusted Tcl and native extensions with the user's permissions.
Entry declarations, supervised lifetimes, resource limits, and archive inventories
are not sandboxing or publisher authentication. Retrieve
`machteld/guide/contract` for cross-command rules and
`machteld/guide/execution-model` for GUI-safe composition of blocking and evented
operations.
