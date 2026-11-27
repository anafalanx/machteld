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

A check can report several independent syntax errors in a module. The
checker resumes at the next recognizable top-level declaration and records
the original source span for each error. A successful check returns an
empty list. It validates example operands
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

## Binary64 measurements

`to_binary64($value)` converts an integer or decimal and returns
`result<binary64,problem>`. `exact_decimal($binary)` recovers the exact
stored value as a decimal.
Binary64 addition, subtraction, multiplication and division accept two binary64
values and return checked results. In `($raw * $gain)? + $offset`, a
multiplication failure propagates before the addition. Overflow reports
`BINARY64_OVERFLOW` and a zero divisor reports `DIVIDE_BY_ZERO`. The domain
includes subnormal values and a single zero. NaN and infinities fail the Tcl,
SQL and JSON boundary checks. A typed SQL parameter or column uses REAL.
The runnable `examples/typed-calibration` project reads a measurement from JSON.

## Ordering and boolean conditions

Use `$start <= $at && $at < $stop` to check a half-open interval. Integers
and exact decimals compare numerically. Compare a `binary64` reading with
another `binary64` value. Text compares in ordinal,
case-sensitive order, so `'007' < '7'` is true. Compare instants with
instants and local date-times with local date-times. Two values of the same
distinct type inherit the order of its scalar base when that order exists.

Boolean operators are `!`, `&&` and `||`. The left operand determines
whether `&&` or `||` evaluates the right operand, including any function
calls or error propagation it contains.

## Recovering from a typed failure

Use `match` on a `result<T,E>` to handle each outcome locally.
`ok($value)` binds a `T`, and `err($reason)` binds an `E`. Both cases
are required. A nested match can inspect an application's declared error
variants. Use `?` to propagate the typed failure to the caller.

## List literals and length

`[1, 2, 3]` builds a `list<int>`. Elements evaluate once from left to
right. The declared return type in `fn .names() -> list<text> => []`
supplies the type of the empty list. In `[[], ['007']]`, the second
element supplies the missing type. Use `len(value)` to count list
elements, map entries, bytes or Unicode code points in text.

## Argument labels

Authors can require names at X call sites. A parameter declared as
`from $origin: text` takes `from: 'North'`. An ordinary `$value: text`
parameter takes its value positionally. Supply arguments in declaration
order. The exported signature in the application's offline reference
shows the exact labels. Tcl callers still pass the values positionally.

## Passing callbacks

A `callable<int,text>` accepts one integer and returns text. A
`callable<text>` accepts zero arguments. Take a named function as a value
with `.name`, `.module::name` or `.identity<int>`. Invoke a local callable
as `$f(42)`. Callable parameters are positional. A labelled function can
provide a positional adapter that supplies the required labels.

`bind(.caption, $station)` captures the current station as the first
argument of `.caption`. The remaining parameters are supplied on each
invocation. Tcl can invoke the returned prefix with `{*}$prefix 42`.
Declare an existing Tcl procedure as an `extern fn` to use it as a
typed callback. The compiler guide includes a complete capture example.

## Sharing state with a callback

Create a typed cell with `using $state ::= ref('draft') { ... }`. A
`ref<text>` parameter accepts its reference. Read it with `ref_get($state)`
and update it with `ref_set($state, 'final')`. Binding the reference into
a callback lets each invocation read the latest value. Binding the result
of `ref_get` captures an ordinary snapshot.

Tcl can retain and pass back the reference during the owner's scope.
Leaving that block closes the cell on every exit. Subsequent access raises
`APPCOMPILER REFERENCE EXPIRED`. A reference belongs to one generated
application and interpreter. Use `ref_same` to compare two live references
for identity.

## Owning a Tk window in X

`using $w ::= tk_open('Observations')? { ... }` owns a window. Create
a `tk_canvas`, `tk_label` and `tk_button` with the corresponding functions,
place them with `tk_grid`, and dispatch events with `tk_wait($w)`.
`tk_on_click` takes a `callable<tk_click,unit>`. Its event carries the
window, canvas, integer `x` and `y`, and an optional occurrence key.
`tk_on_action` on a button supplies a `tk_action` with its window and button.

Give related rectangles and labels the same key. Save that key to restore
the highlight after a redraw. A closed window and deleted canvas items
reject further use. The compiler guide documents widget operations and the
validated Tcl renderer bridge. The `examples/graphviz-table/typed-window.dict`
project combines an X-owned UI with an existing Tcl Graphviz renderer.

An uncaught callback fault ends its operation and runs scoped cleanup.
Healthy windows keep receiving events. Use
`::application::@events::on_fault $commandPrefix` in a Tcl entry to receive
the fault dictionary with `operation`, `message` and the original Tcl
`options`. A mapped X location appears in `-appcompilerlocation`.
The default sink writes to stderr. `::application::@events::last_fault`
returns the latest report even on a launch without a console.

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

## Releasing library resources

For other library-owned resources, declare a closer in the type's own
module with `resource .reader using .close`. A block beginning with
`using $reader ::= .readers::open($path)?` acquires the value and releases
it on every exit after successful acquisition. Nested scopes release in
reverse order. The compiler guide documents cleanup failure reporting
and the runnable file-reader project.

## Writing SQLite transactions

Use `using $tx ::= sql_begin($path)? { ... }` inside a function returning
`result<T,problem>`. Pass the binding to `sql_exec($tx, $sql, ...)?` for
one bound INSERT, UPDATE or DELETE, and to the typed read functions to see
the transaction's pending writes. Call `sql_commit($tx)?` when the entire
operation succeeds. Leaving the scope before commit rolls back every write,
including on an early success return. Failed writes and failed commits also
end the transaction. The compiler guide includes the stable problem codes
and a worked JSON import with replay, provenance and historical disagreements.

## Running an application tool

Declare a companion executable with `tool .converter = 'tools/converter.exe'`.
Calling `.converter()?` resolves it beside the project manifest during
development and beside the archive after delivery. Copy the executable to
that relative location when distributing the application. Add `export` to
share the declaration with other modules or a Tcl entry.

`capture_process(exe, argv, input, limit, timeout_ms)` accepts an absolute
native `.exe` path, a `list<text>` of individual arguments and stdin bytes.
It waits for the process tree while draining both output pipes. The limit
is 0 through 1,048,576 bytes per stream. Zero milliseconds disables the
deadline. The result is `result<process_output,problem>`. Inspect `status` and
`exit` even on success, then read `stdout` and `stderr` as bytes. Each stream
has a retained-byte count and a truncation flag, for example `stdout_retained`
and `stdout_truncated`. The compiler guide lists fields and problem codes.

Use `stream_process(exe, argv, input, chunk_bytes, timeout_ms, stdout_cb,
stderr_cb, done_cb)` for an event-driven consumer. The two chunk callbacks
accept raw `bytes` and return `result<unit,problem>`. Choose 1 through
65,536 bytes per chunk. Normal completion calls `done_cb` after both EOFs
with `result<process_exit,problem>`. The record contains `status`, `exit`,
`stdout_bytes` and `stderr_bytes`. A successful start immediately returns a
`process_stream` handle. `cancel_process` delivers a terminal cancellation.
`close_process` and scope cleanup stop silently. If a chunk handler throws
after canceling or closing its stream, the application fault sink receives
the original exception as `process-stdout` or `process-stderr`. Streams
started in a typed Tk handler stop silently when its window closes. Streams started
from their chunk or completion callbacks inherit the same owner. The
compiler guide has a headless event-loop example. For explicit PATH lookup, `find_executable`
accepts a bare .exe name and searches absolute PATH directories.

## Waiting for typed workers

Declare `worker .lookup($request: .query) -> result<.answer,problem>`
with its function body. `start .lookup($request)` returns a
`task<.answer>`. `await($task)` returns the checked result while other
handlers remain responsive. Each worker has a supervised process, private
message pipes and its own live resources. A typed entry already has
application scope. In mixed Tcl/Tk code, obtain the window owner from
`::application::workers window .panel`. Use
`::application::workers event $owner commandPrefix ?arg ...?` as the
button command. The application fault sink receives both immediate faults
and faults after a pending await. Use `workers handle` for direct calls
whose synchronous result or exception belongs to the Tcl caller.

Destroying the window cancels its tasks and unwinds waiting handlers.
`start_app` selects application ownership, allowing a different handler to
await the result after that window closes. `cancel($task)` requests explicit
cancellation. Worker messages have a 65,536-byte limit. The compiler guide
describes the portable types, timeout setting and problem codes. Finite
binary64 measurements keep their bits through a round trip. Local resources,
callables and shared references stay in the process that owns them.
