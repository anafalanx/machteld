---
id: machteld/command/version
type: command
title: version
summary: Return the Machteld package and runtime API version.
commands: version
---

# version

## Synopsis

```tcl
version
```

## Arguments and options

Takes no arguments or options.

## Results

Returns `22`, the same value returned by `package require machteld` in this <!-- machteld-version-current -->
tree. The version is one natural number, and only a change to the runtime
makes a new one.

## Errors

Only Tcl wrong arity is expected.

## Lifetime and timeouts

Pure constant query with no retained state or timeout.

## Examples

```tcl
package require machteld 22-
puts "Machteld [version]"
```

## Constraints

This reports Machteld, not Tcl, Tk, SQLite, Windows, or documentation-schema
versions. Use `docs status` and `store version` for related exact versions.
Machteld 22, in preparation, is unsigned and distinct from the previously signed
`dist/0.21` release. A version number does not identify the exact source state,
prove that a build passed acceptance, or authenticate a publisher. Use
artifact hashes and verification receipts, the executable's own `manifest`, and
its reference corpus when provenance matters. Incremental builds also carry an
embedded development identity; clean reconstruction legitimately omits it.

## See also

`machteld/command/manifest`, `machteld/command/docs#status`,
`machteld/command/store#version`.
