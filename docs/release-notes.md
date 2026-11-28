---
type: release-notes
title: Release notes
description: Changes to the X compiler, runtime and project packer in Machteld 0.51.
tags: [machteld, release, compiler]
---

# Machteld 0.51

Machteld 0.51 keeps Tcl package API 30 and X language edition 1. One
executable checks, tests, packs and runs typed or mixed Tcl/X applications.

## Compiler and runtime

- X generates simpler Tcl for conditional branches and calls between checked
  X functions. Public calls from Tcl and values returned by external commands
  retain their boundary checks.
- Collection updates reuse values where ownership permits. The compiler
  releases discarded expression and match results earlier, reducing
  unnecessary copies and the lifetime of resources held by those results.
- Typed SQLite row readers, JSON conversion, binary64 arithmetic, exact
  decimals and temporal values have specialized paths for common inputs.
  Benefits depend on data shape and the host executing the generated Tcl.
- The native `intervals gaps` operation sorts and merges closed integer
  intervals and returns their uncovered ranges. It accepts flat endpoint
  lists from SQLite or X. [Command reference](reference/machteld/command/intervals.md)
- `project pack` and `project rebuild` include editable source and the
  compiler by default. Supply `--without-source` and `--without-compiler`
  independently to omit either from delivery.

## Upgrading

Existing application archives run their packaged Tcl. Repack from the
editable project with the new compiler to obtain the new generated code.
Use the host's `project` commands when choosing a newer compiler: an
archived compiler reproduced from an earlier delivery retains its original
code. Applications that call `intervals gaps` require a host providing
that command. Check `manifest` when targeting multiple API-30 releases.

Use `machteld.exe --version` to see the product version and
`machteld.exe --version --api` for the Tcl package API. For the language
manual run `machteld.exe --docs get X`.
