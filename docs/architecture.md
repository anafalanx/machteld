---
type: architecture
title: Architecture
description: How the executable, native palette, prelude, entry gate, and wrappers fit.
tags: [machteld, architecture, tcl, windows]
---

# Architecture

The product has three layers:

1. **Native core.** C commands wrap Win32 Job Objects and process creation,
   ConPTY, directory and reparse-point traversal, ReadDirectoryChangesW,
   WinHTTP, BCrypt, JSON, and statically linked SQLite.
2. **Tcl runtime.** The prelude adds `scope`, `pty expect/strip`, `cli`, `log`,
   `worker`, `pool`, `pmap`, `docs`, `help`, and `wrap`, then provides package
   `machteld 0.10.0`.
3. **Program.** An opted-in entry remains ordinary Tcl. It receives normal
   `argv` and resolves palette commands through `::machteld` on the global
   namespace path.

Startup registers the native commands, loads the embedded prelude, and applies
the entry gate before Tcl evaluates a program. The gate parses the first command
without evaluating it. Interactive startup is still available when no file is
selected; `--help`, `--version`, `--docs`, and the subordinate `wrap` route are
handled by the host.

## Hosts and archives

The distribution executable contains Tcl/Tk libraries, docs, the prelude, and
console and GUI basekits. The console host enters `Tcl_Main`; the GUI host enters
`Tk_Main` without creating a console. The console host initializes Tk only after
`package require Tk`; the GUI host initializes Tk at startup because it is a
windowed host.

`wrap` copies one basekit, the complete Machteld prelude, Tcl/Tk libraries, and
the program into an appended zipfs. Both basekits link the same native core and
SQLite, so a wrapped entry sees the same programmatic Machteld 0.10.0 API. The
complete versioned reference corpus is copied into wrapped tools; nested
wrapping basekits remain distribution-only and are not copied recursively.

## Self-description

Native metadata is an explicit table checked against the C registrations while
building. Tcl commands register explicit facts with `MetaDefine`. `manifest`
merges the two tables; an incompatible duplicate fails loudly. The sole planned
extension is `pty`: Tcl adds `expect` and `strip` to the native ensemble.

No command body, helper name, option-looking comment, or trailing function is
scanned to infer public behavior. Refactoring implementation text cannot change
the advertised API.

The documentation build transforms pinned upstream Tcl/Tk manpages into
normalized Markdown while preserving source and HTML representations. It
combines those pages with authored Machteld command references, creates a
deterministic catalog/search index, and hashes the corpus. `docs` reads only
this trusted self-mounted payload and exposes exact lookup, sections, bounded
search, verification, provenance, and safe extraction.

## Lifetime

The host owns, but does not join, a root Job Object configured to kill its
members when the host closes its last handle. `child`, `run`, pool workers, and
PTYs are born into both that root job and a narrower per-command job. `scope`
gives a lexical lifetime inside the process. `detach` is the explicit exception:
on success it belongs to no Windows job and creates an independent process tree.
An enclosing Windows job may forbid breakaway, in which case launch is rejected.
