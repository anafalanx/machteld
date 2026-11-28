---
id: machteld/command/version
type: command
title: version
summary: Query the runtime API or the product version.
commands: version
---

# version

## Synopsis

```tcl
version ?-product?
```

## Arguments and options

Omit the option to query the Tcl package API. Use `-product` to get the
version shown in the host's help and Windows file properties.

## Results

`version` returns the same value as `package require machteld` and
`machteld.exe --version --api`, currently `30`.
`version -product` and `machteld.exe --version` return `0.51`.

## Errors

An unsupported option or extra arguments raise `TCL WRONGARGS`.

## Lifetime and timeouts

Pure constant query with no retained state or timeout.

## Examples

```tcl
package require machteld 30-
puts "Machteld [version -product]"
```

## Constraints

This reports Machteld, not Tcl, Tk, SQLite, Windows, or documentation-schema
versions. Use `docs status` and `store version` for related exact versions.
A version number does not identify the exact source state,
prove that a build passed acceptance, or authenticate a publisher. Use
artifact hashes and verification receipts, the executable's own `manifest`, and
its reference corpus when provenance matters. Incremental builds also carry an
embedded development identity; clean reconstruction legitimately omits it.

## See also

`machteld/command/manifest`, `machteld/command/docs#status`,
`machteld/command/store#version`.
