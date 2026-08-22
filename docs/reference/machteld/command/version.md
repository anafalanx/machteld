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

Returns `0.13.0`, the same value returned by `package require machteld` in this
release.

## Errors

Only Tcl wrong arity is expected.

## Lifetime and timeouts

Pure constant query with no retained state or timeout.

## Examples

```tcl
package require machteld 0.13.0
puts "Machteld [version]"
```

## Constraints

This reports Machteld, not Tcl, Tk, SQLite, Windows, or documentation-schema
versions. Use `docs status` and `store version` for related exact versions.

## See also

`machteld/command/manifest`, `machteld/command/docs#status`,
`machteld/command/store#version`.
