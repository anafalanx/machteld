---
id: machteld/package/application-compiler
type: package
title: Checking, testing and packing typed applications
summary: Use the embedded compiler to check, test, pack and rebuild typed applications and mixed Tcl/Tk projects.
commands: application-compiler, package require application-compiler, project, ::appcompiler::check, ::appcompiler::compile, ::appcompiler::project::test
---

# Checking, testing and packing typed applications

The integrated host supplies the Tcl compiler package and the project driver.
Use `machteld.exe project check project.dict`, then `project test`,
`project run` or `project pack project.dict app.machteld`. Run the result
with `machteld.exe app.machteld`. Use `--project` to select the built-in
driver explicitly when the current directory contains a file named `project`.
Editable archives also carry a copy of their compiler under `compiler/`
and their manifest and original files under `project/inputs/`.

## Checking an example

```tcl
package require machteld
package require application-compiler 0.1

set modules [dict create sample {
    export fn .seconds($minutes: int) -> int => $minutes * 60
    example .seconds(2) => 120
}]
puts [::appcompiler::check $modules]
```

A successful check returns an empty list. It validates example operands
without evaluating them. To run all examples in an extracted application,
use the driver from its compiler directory.

```text
machteld.exe local-compiler/driver.tcl test working-source/application.dict
machteld.exe local-compiler/driver.tcl pack working-source/application.dict revised.machteld
machteld.exe local-compiler/driver.tcl docs revised.machteld search seconds
```

Packing requires a host with archive support and SQLite FTS5. Each public
function or type gets a Markdown page. After a search, pass a returned ID to
`docs revised.machteld get ID`. To read the host's manual through this driver,
use `docs --runtime get ID`. The compiler's bundled `README.md` describes
extracting the driver and sources, the project manifest, and typed examples.

## Recovering from a typed failure

Use `match` on a `result<T,E>` to handle each outcome locally.
`ok($value)` binds a `T`, and `err($reason)` binds an `E`. Both cases
are required. A nested match can inspect an application's declared error
variants. Use `?` to propagate the typed failure to the caller.

## Generic application code

Generic functions, records and closed choices declare dotted type
parameters, for example `record .page<.item> { items: list<.item> }`.
X normally infers the type arguments to a function from its arguments.
A Tcl caller supplies an explicit list of concrete types before the
ordinary arguments of a generic export. Use `project docs ARCHIVE get
fn/MODULE/NAME` for its signature. The compiler guide and the
`examples/typed-pages` project show how to share one function across
several record types.

## Keeping an existing Tcl/Tk entry

Set `tclEntry main.tcl` in place of `entry {module function}`. Start with
`modules {}` for an all-Tcl project. List the subsidiary Tcl files and
assets used by the application, then add typed modules one at a time.
An exported function becomes a Tcl command such as
`::application::captions::caption`. In the other direction, a typed
`extern fn` declaration identifies an existing Tcl command prefix and its
argument and result types. Both run synchronously in the same interpreter.
Tk widgets, bindings and the event loop can stay in their original Tcl files.

In a source run, `argv0` identifies the Tcl entry. In a packed run it
identifies the public archive. Use `file dirname [info script]` to find
sibling files in both forms. If a legacy script starts only when its
filename equals `argv0`, supply a short entry that sources it and calls
its main procedure. The compiler guide describes this migration and the
Tcl representations for typed values and failures.

## Reading SQLite rows

Source applications can call `sql_one<.row>`, `sql_optional<.row>`, or
`sql_many<.row>` with the database path, one SQL query, and its positional
bindings. The record fields name the expected columns. A missing row and
a NULL column within a present row are distinct. Reads use the host's
typed SQLite interface, documented under `machteld/package/sqlite3`.
The compiler guide includes the type mappings, error codes and a runnable
historical lookup.

For temporal evidence, `local_datetime` holds a recorded calendar date
and wall time. `instant` holds a point on the UTC timeline. Call
`parse_local_datetime` for a clock reading, `resolve_offset` to apply known
minutes east of UTC, and `parse_instant` for text carrying a known UTC
offset. An unresolved wall time can remain a local date-time. The runtime
uses the same rules on every machine. The Tcl, JSON and SQL representations
of instants are UTC strings with nine fractional digits, for example
`2026-10-25T00:30:00.000000001Z`. This preserves nanosecond precision and
chronological ordering in a SQLite TEXT index with BINARY collation.

`resolve_zone(local_datetime, text)` returns `result<list<instant>,problem>`.
Pass an exact zone name such as `Europe/Brussels`. A successful list contains
every possible UTC instant in chronological order. The Brussels reading
`2026-10-25T02:30:00` yields two instants, while `2026-03-29T02:30:00` yields
an empty list. Unknown names give `INVALID_ZONE`. The rules reside in the
executable and cover local and UTC years 0001 through 2099. The compiler
guide documents range errors and historical offsets.

## Writing SQLite transactions

Use `using $tx ::= sql_begin($path)? { ... }` inside a function returning
`result<T,problem>`. Pass the binding to `sql_exec($tx, $sql, ...)?` for
one bound INSERT, UPDATE or DELETE, and to the typed read functions to see
the transaction's pending writes. Call `sql_commit($tx)?` when the entire
operation succeeds. Leaving the scope before commit rolls back every write,
including on an early success return. Failed writes and failed commits also
end the transaction. The compiler guide includes the stable problem codes
and a worked JSON import with replay, provenance and historical disagreements.
