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
When `qualified_only` is true, use the command's full name. For example,
`::machteld::clipboard owned` queries native Windows clipboard ownership.
Some entries also expose `defaults` and `limits`; these fields are only present
where explicitly authored, not a complete resource-policy model for all verbs.
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

## Shell queries

```text
machteld.exe --manifest --json
machteld.exe --manifest command child --json
machteld.exe --manifest command child wait --json
machteld.exe --manifest package Tk --json
machteld.exe --manifest package sqlite3 --probe --json
machteld.exe --manifest package machteld::browser --probe --json
```

The default query returns the runtime version, public command names, Tcl,
Tk and Machteld's public bundled packages. A command or subcommand query returns its `facts`
from the same `manifest` dict that Tcl programs see. Its `doc` value is
an exact ID for `--docs get`. Package queries report the registered versions,
whether the package is loaded in this process, and whether a probe ran.
Reading a packaged index does not initialize Tk, start a browser, open a
database or contact the network.

The optional SQLite probe loads the shipped binding, creates an in-memory
FTS5 table using the trigram tokenizer, inserts and matches text, and closes
the database. Its response includes the engine version and checked features.
The browser probe checks the same installation paths as `browser launch`.
It returns `detected` and, when found, an `executable` path. It reads file
metadata without launching a browser or using a profile or socket.
Other package probes return `MANIFEST unsupported`. An unprobed package's
presence describes what this executable ships. External services, browser
installations, and desktop access depend on the environment.

Successful queries write `{"ok":true,"result":{...}}` to stdout and exit 0.
The result carries `schema: 1`. Failed queries write one JSON error to stderr
and exit 1. The error includes `domain`, `code`, `message` and `doc`.
Omitting `--json` returns the result as a Tcl dict.

## Constraints

The manifest describes structural contract facts, not prose semantics or every
possible Tcl-level error. `codes` is the closed set of Machteld-domain failures;
Tcl itself can still report wrong arity, lookup, or conversion errors. Consult
the linked reference page for defaults, lifetimes, constraints, and examples.
Query the executable actually being used: equal package versions do not imply
equal development and signed-release manifests.

## See also

`machteld/command/docs`, `machteld/command/version`,
`machteld/guide/contract`.
