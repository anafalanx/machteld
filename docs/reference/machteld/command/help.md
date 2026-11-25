---
id: machteld/command/help
type: command
title: help
summary: Return concise human-readable documentation by delegating exact lookup or search to docs.
commands: help
---

# help

## Synopsis

```tcl
help ?query ...?
```

## Arguments and options

With no query, returns the short documentation bootstrap. Its first screen
identifies the versions of the manuals carried by the runtime. Query `docs
status` for the full inventory.

A query can be an exact stable document ID such as `machteld/command/run` or
natural search words. Multiple words are joined as one search query. For stable,
structured programmatic access use `docs` directly.

## Results

Returns human-oriented text. Exact IDs return their document; a nonexact query
returns concise ranked search results and guidance for retrieving one. Output
format and wording are not a machine protocol.
An exact page longer than the default `docs get` bound is followed by a literal
continuation hint naming the document ID and next offset.

## Errors

Documentation failures use `HELP notfound`, `HELP oserror` or
`HELP unsupported`. A missing corpus produces an explanatory response from
bare `help`.

## Lifetime and timeouts

Reads only the executable's trusted, self-mounted reference payload. It performs
no network access, retains no resource, and has no timeout.

## Examples

```tcl
puts [help]
puts [help machteld/command/child#wait]
puts [help channel binary encoding]
```

## Constraints

For agents and programs, `docs get`, `docs search`, and their bounded result
dicts are the stable interface. `help` exists for concise discovery and people.
If consulting another host because this one omits the reference, match its
runtime artifact identity as well as its package version. Different builds may
report the same version while containing different code or references. The
older signed release's reference describes that release, not this one.

## See also

`machteld/command/docs`, `machteld/agent`.
