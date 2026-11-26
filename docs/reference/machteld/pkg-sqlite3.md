---
id: machteld/package/sqlite3
type: package
title: SQLite connections, FTS5 and typed parameters
summary: Query the shared SQLite engine from Tcl, bind numbered parameters, and enable verified connection settings.
commands: sqlite3, package require sqlite3, sqlite3 eval, sqlite3 eval -parameters, FTS5, trigram, ::sqlite3
---

# SQLite connections, FTS5 and typed parameters

## Open a database

`package require sqlite3` loads the SQLite 3.53.4 Tcl binding. `sqlite3 db filename ?option value ...?` creates the Tcl command `db`. Use `:memory:` for an in-memory database and `db close` to release it. Choose a fresh command name. Each connection owns its transaction, busy handler and prepared statements. Workers open their own connections.

| Open option | Purpose |
| --- | --- |
| `-readonly boolean`, `-create boolean` | Control file access and creation. Use `-readonly 1 -create 0` to open an existing database for reading. |
| `-foreignkeys boolean`, `-defensive boolean` | Request foreign-key enforcement and SQLite defensive mode individually. The binding applies each specified setting and reads it back before it publishes the command. Omitting them retains the engine defaults. |
| `-uri boolean`, `-nofollow boolean`, `-vfs name` | Enable URI filenames, reject following symbolic links at open, or choose a registered SQLite virtual filesystem. |
| `-nomutex boolean`, `-fullmutex boolean` | Select SQLite's per-connection mutex policy. Keep the Tcl command on its interpreter thread. |

`sqlite3 -version` and `sqlite3 -sourceid` identify the engine. `sqlite3 -has-codec` returns 0. `db config enable_fkey` and `db config defensive` report the effective safeguards.

The host registers `sqlite3` in the initialized script or archive interpreter
and in each supervised worker. A plain `interp create` child starts without
this registration. Run database work in an initialized interpreter and open
its connection there.

## Query and bind

`db eval ?-parameters bindings? ?-asdict? ?-withoutnulls? sql ?rowName? ?script?` returns a flat Tcl list in row and column order when there is no script. A row script runs in its caller's context. Give a name for a row array, or combine a row name with `-asdict` for a dictionary. `-withoutnulls` omits SQL NULL fields in a row callback. `db onecolumn sql` returns the first column of the first row. `db exists sql` reports whether SQL produced a row.

A numbered binding maps the positive decimal slot number to a typed Tcl list. Write `?1`, `?3` and so on in braced SQL. Gaps need no binding, and repeated uses of a slot read the same value. SQLite identifies the placeholders during preparation, including when the text contains comments or quoted question marks. Named SQLite placeholders keep their upstream variable binding.

| Binding | SQLite value |
| --- | --- |
| `{null}` | SQL NULL |
| `{integer value}` | Signed 64-bit integer |
| `{real value}` | Floating-point number, excluding NaN |
| `{text value}` | Valid Unicode encoded as UTF-8, preserving embedded NUL |
| `{blob bytes}` | Binary data, including an empty bytearray |

```tcl
package require sqlite3
sqlite3 catalog :memory: -foreignkeys 1 -defensive 1
try {
    catalog eval {CREATE VIRTUAL TABLE books USING fts5(title, tokenize='trigram')}
    catalog eval -parameters {3 {text Bruxelles-Nord}} {INSERT INTO books(title) VALUES(?3)}
    set bindings [dict create 8 [list text xell]]
    puts [catalog eval -parameters $bindings {SELECT title FROM books WHERE books MATCH ?8}]
} finally {catalog close}
```

FTS5 can index its own content or share row IDs with application tables through an external-content index. The application maintains or rebuilds an external-content index when rows change. The file, SQLite engine and FTS5 implementation are shared with `store`. Each API uses a separate connection.

## Connection operations

| Methods on `db` | Use |
| --- | --- |
| `transaction ?deferred\|immediate\|exclusive? script`, `interrupt` | Group work in a transaction or request cancellation of active SQL. Nested transactions use savepoints. |
| `config ?option? ?boolean?`, `busy callback`, `timeout milliseconds`, `progress n callback` | Inspect or change connection behavior, configure waiting for locks or install progress callbacks. |
| `cache flush`, `cache size n`, `complete sql`, `version` | Manage prepared-statement caching, check whether SQL text is complete or read the engine version. |
| `changes`, `total_changes`, `last_insert_rowid`, `status step\|sort\|autoindex\|vmstep`, `errorcode`, `erroroffset` | Read connection statistics and diagnostics. |
| `nullvalue ?string?`, `bind_fallback ?callback?` | Choose the Tcl rendering of SQL NULL or the callback for otherwise unresolved named parameters. |
| `copy conflict table filename ?separator? ?nullMarker?`, `incrblob ?-readonly? ?schema? table column rowid` | Import delimited rows or open an incremental BLOB channel. Close the channel after use. |
| `backup ?schema? filename`, `restore ?schema? filename` | Copy database contents into a file or into the current connection. For create-only verified publication use `machteld/package/sqlite`. |
| `serialize ?schema?`, `deserialize ?-maxsize bytes? ?-readonly boolean? ?schema? bytes` | Export or load a database image as a bytearray. |
| `collate name script`, `collation_needed script`, `function name ?options? script` | Define a collation or SQL function in Tcl. Function options include `-argcount`, `-deterministic`, `-directonly`, `-innocuous` and `-returntype`. |
| `authorizer`, `commit_hook`, `rollback_hook`, `update_hook`, `wal_hook`, `trace_v2` | Install callbacks on this connection. Use `trace_v2 ?callback? ?mask?` for statement tracing and profiling. |
| `close` | Delete the command and release the connection. |

The build omits loadable extensions, shared cache and deprecated SQLite interfaces. Use `trace_v2` for trace and profile events. Legacy `trace` and `profile` may accept a callback without delivering events. The compatibility operations `-key` and `rekey` do not encrypt data. The `format` (query result formatter), `preupdate`, `unlock_notify` and `enable_load_extension` operations report that the requested feature is unavailable in this build.

## Connection callbacks

The connection calls Tcl synchronously. Use a fully qualified command prefix when installing a callback. Pass an empty script to remove an installed hook. An update notification can precede a rollback.

| Registration | Arguments appended to the callback | Result |
| --- | --- | --- |
| `db authorizer prefix` | `action detail1 detail2 schema triggerOrView` at SQL preparation. For `SQLITE_READ`, the details identify the table and column. Unused fields are empty. | Return the literal `SQLITE_OK` to allow the action, `SQLITE_DENY` to reject the statement, or `SQLITE_IGNORE` for action-specific suppression. Ignoring a column read supplies SQL NULL. |
| `db commit_hook script` | None | Return integer 0 to allow the commit. A nonzero integer or Tcl error rolls the transaction back. |
| `db rollback_hook script` | None | Notification after rollback. The hook has no veto. |
| `db update_hook prefix` | `operation schema table rowid` for changes to rowid tables. The operation is `INSERT`, `UPDATE` or `DELETE`. | Notification only. SQLite omits some changes, including those to WITHOUT ROWID tables. |
| `db wal_hook prefix` | `schema frameCount` after a write commits in WAL mode. The count is the number of frames in the WAL. | Return integer 0 for success. A SQLite error code can reach the caller after the transaction has committed. |
| `db busy prefix` | `attempt`, starting at zero | Return 0 to retry the lock or a nonzero integer to give up. Installing `db timeout milliseconds` replaces this handler. |
| `db progress n script` | None, about every `n` SQLite virtual-machine instructions | Return 0 to continue. A nonzero integer or Tcl error interrupts the query. |
| `db bind_fallback prefix` | The unresolved named SQL parameter, including its prefix | Return the value to bind, or raise a Tcl error to reject the query. The usual behavior for an unresolved variable is to bind SQL NULL. |

For example, an application can record which row changed and discard those notifications if its transaction rolls back.

```tcl
sqlite3 db :memory:
try {
    db eval {CREATE TABLE notes(title TEXT)}
    set ::changes {}
    db update_hook [list lappend ::changes]
    db eval {INSERT INTO notes VALUES ('first')}
    puts $::changes
    # INSERT main notes 1
} finally {db close}
```

## SQL functions and collations

`db function name ?-argcount n? ?-deterministic? ?-directonly? ?-innocuous? ?-returntype type? prefix` appends the SQL arguments in order. Tcl receives bytearrays for BLOBs and the connection's `nullvalue` string for SQL NULL. A callback error fails the SQL expression. The default return type `any` chooses a storage class from the Tcl object's internal type. The explicit types are `integer`, `real`, `text` and `blob`. An `integer` result that cannot convert to a wide integer falls back to real and then text. A `real` result that cannot convert to a double falls back to text. A callback that completes with Tcl's break code produces SQL NULL.

For example, `db function lower_label -argcount 1 -deterministic -returntype text {string tolower}` registers a scalar function for `SELECT lower_label('North')`. Specify `-directonly` to restrict use to top-level SQL. Declare `-deterministic` only when the same inputs always produce the same result and `-innocuous` only when the function has no side effects or access to sensitive information.

`db collate name prefix` calls `prefix left right`. Return a negative integer, zero or a positive integer for the sort order. `db collation_needed prefix` calls `prefix name` when SQL requests an unknown collation, giving the application a chance to register it.

## Trace and profile events

`db trace_v2 prefix ?mask?` accepts a Tcl list with any of the four event names below, or their numerical bit values. The default is `statement`. Use `db trace_v2 {}` to stop. The callback receives the listed arguments directly. Select one event type when the argument shapes would otherwise be ambiguous.

| Mask | Callback arguments |
| --- | --- |
| `statement` (1) | An opaque statement identifier and the SQL text. Trigger execution can supply a comment in place of the top-level SQL. |
| `profile` (2) | The statement identifier and the approximate elapsed time in nanoseconds. |
| `row` (4) | The identifier of the statement that produced the row. |
| `close` (8) | The opaque database connection identifier. |

The callback result is ignored. Use the identifiers only to correlate events during the lifetime of their objects. For example, `db trace_v2 [list lappend ::timings] profile` appends a statement identifier and duration to `::timings` when a statement finishes.

## Errors and lifetime

Missing or malformed numbered values raise `MACHTELD SQLITE parameter`. An unsuccessful open reports an error before handing the caller a connection. SQLite prepare, execution, constraint and locking failures raise Tcl errors. Use `try ... finally` around a connection, and handle database errors where the application can roll back or retry. A busy timeout bounds lock waiting only. Run long synchronous queries in a worker when Tk must remain responsive.

Machteld's key/value API is documented in `machteld/command/store`. SQLite publishes additional examples for the upstream binding. [SQLite Tcl interface](https://www.sqlite.org/tclsqlite.html)
