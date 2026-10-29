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

Returns `0.22`, the same value returned by `package require machteld` in this <!-- machteld-version-current -->
candidate tree.

## Errors

Only Tcl wrong arity is expected.

## Lifetime and timeouts

Pure constant query with no retained state or timeout.

## Examples

```tcl
package require machteld 0.22
puts "Machteld [version]"
```

## Constraints

This reports Machteld, not Tcl, Tk, SQLite, Windows, or documentation-schema
versions. Use `docs status` and `store version` for related exact versions.
The current candidate is unsigned and distinct from the previously signed
`dist/0.21` release. A version string does not identify the exact source state,
prove that the candidate passed acceptance, or authenticate a publisher. Use
artifact hashes and verification receipts, the executable's own `manifest`, and
its reference corpus when provenance matters. Incremental builds also carry an
embedded development identity; clean reconstruction legitimately omits it.

## See also

`machteld/command/manifest`, `machteld/command/docs#status`,
`machteld/command/store#version`.
