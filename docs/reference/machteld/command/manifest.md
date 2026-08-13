---
id: machteld/command/manifest
type: command
title: manifest
summary: Return the structured public command contract of the exact running executable.
commands: manifest
---

# manifest

## Synopsis

```tcl
manifest
```

## Arguments and options

Takes no arguments or options. Navigate the result with ordinary Tcl `dict`
commands; the API intentionally adds no manifest query language.

## Results

Returns a dict keyed by public command. Entries contain applicable fields:
`kind` (`c` or `tcl`), `domain`, raised `codes`, protocol-data `replycodes`,
top-level `options`, `args`, `returns`, and `subcommands`. Each subcommand entry
can carry its own options, fixed result keys, and stable exact `doc` identifier.
Every command carries a stable exact `doc` identifier; commands without a
subcommand vocabulary have no subordinate identifier to publish.

## Errors

Only Tcl wrong arity or an internal metadata-conflict error is expected. The
build and runtime suite reject duplicate/conflicting authored metadata before a
release artifact is accepted.

## Lifetime and timeouts

Returns a newly assembled Tcl value and retains no resource. There is no
timeout.

## Examples

```tcl
set api [manifest]
puts [dict keys $api]
puts [dict get $api child subcommands wait options]
puts [dict get $api run codes]
```

## Constraints

The manifest describes structural contract facts, not prose semantics or every
possible Tcl-level error. `codes` is the closed set of Machteld-domain failures;
Tcl itself can still report wrong arity, lookup, or conversion errors. Consult
the linked reference page for defaults, lifetimes, constraints, and examples.

## See also

`machteld/command/docs`, `machteld/command/version`,
`machteld/guide/contract`.
