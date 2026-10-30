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

With no query, returns the short agent/human documentation bootstrap. When the
reference pack is present, its first screen identifies the complete offline
Machteld 22, Tcl 9.0.4, and Tk 9.0.4 references carried by the executable.
Without the pack, it explains the omission and points to the full same-version
Machteld executable, `wrap --with-docs`, `manifest`, and `docs schema`.

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

Documentation failures use `HELP notfound`, `HELP oserror`, or
`HELP unsupported`. The Machteld distribution and tools wrapped with
`--with-docs` carry the reference pack. In default wrapped tools and deliberately
bare/internal hosts, a query reports `HELP unsupported`; bare `help` still
returns explanatory text. Application-provided help is unaffected.

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
