---
id: machteld/package/application-compiler
type: package
title: Checking, testing and packing typed applications
summary: Use the source compiler from a checkout or an editable application archive to check examples, build an application and query its reference.
commands: application-compiler, package require application-compiler, ::appcompiler::check, ::appcompiler::compile, ::appcompiler::project::test
---

# Checking, testing and packing typed applications

An editable application archive carries its development compiler under
`compiler/` and its manifest and source files under `project/inputs/`.
The repository supplies the same package in `packages/application-compiler/`.
To use it in a Tcl script, add the compiler directory to `auto_path` and
call `package require application-compiler 0.1`. The compiler comes from
the project or checkout. The host supplies Tcl and the Machteld commands.

## Checking an example

```tcl
package require machteld
lappend auto_path [file normalize local-compiler]
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

## Reading SQLite rows

Source applications can call `sql_one<.row>`, `sql_optional<.row>`, or
`sql_many<.row>` with the database path, one SQL query, and its positional
bindings. The record fields name the expected columns. A missing row and
a NULL column within a present row are distinct. Reads use the host's
typed SQLite interface, documented under `machteld/package/sqlite3`.
The compiler guide includes the type mappings, error codes and a runnable
historical lookup.

## Writing SQLite transactions

Use `using $tx ::= sql_begin($path)? { ... }` inside a function returning
`result<T,problem>`. Pass the binding to `sql_exec($tx, $sql, ...)?` for
one bound INSERT, UPDATE or DELETE, and to the typed read functions to see
the transaction's pending writes. Call `sql_commit($tx)?` when the entire
operation succeeds. Leaving the scope before commit rolls back every write,
including on an early success return. Failed writes and failed commits also
end the transaction. The compiler guide includes the stable problem codes
and a worked JSON import with replay, provenance and historical disagreements.
