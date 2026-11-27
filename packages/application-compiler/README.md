# Application compiler

The integrated Machteld host includes this package. The compiler also runs
in ordinary Tcl 9 when its package directory is on `auto_path`. For the Tcl
API, the caller supplies a dictionary of
logical module names and source strings, so source files can also come from
a mounted application archive.

When this file comes from an application archive, see
[Editing a delivered application](#editing-a-delivered-application) to
extract the development driver and the original project.

```tcl
package require machteld
package require application-compiler 0.1

set modules [dict create unit {
    export fn .seconds($minutes: int) -> int {return $minutes * 60}
}]
set artifact [::appcompiler::compile $modules ::example]
namespace eval :: [dict get $artifact script]
puts [::example::unit::seconds 2]
```

The example prints `120`. Checking and emission take place before the
explicit `namespace eval` loads the generated procedures. Choose a fresh
application namespace when loading generated code in a shared interpreter.

A function with a single expression can return it with `=>`. For example,
`fn .seconds($minutes: int) -> int => $minutes * 60` has the same signature
and result as the block above. The expression can span lines and use `match`
or `?`. A value-returning function with a block requires an explicit return
on every successful path. The `=>` spelling is provisional.

* `::appcompiler::check $modules` returns a list of diagnostics. An empty
  list means checking succeeded. Each diagnostic has a stable `code`, a
  readable `message`, and a `node` with the module and one-based source
  line and column. `::appcompiler::formatDiagnostic $item` formats one.
* `::appcompiler::compile $modules ?targetNamespace?` returns `script`
  and `sourceMap`. The map indexes generated procedure names and Tcl
  body lines. A failed check raises the error code `APPCOMPILER CHECK`
  with every diagnostic in the Tcl catch option `-diagnostics`.
* `::appcompiler::application $modules entryModule ?entryFunction?` returns
  the same artifact with a complete executable Tcl entry script. The entry
  defaults to `.main` and receives `list<text>`. It returns
  `result<unit,problem>`. Write the script as UTF-8 to run it on Machteld,
  or write it as `main.tcl` in an application directory and use `pack` on
  an archive-capable host. Entry failures report the original source location
  on stderr and exit with status 1.
* Imports and user identifiers match case exactly. The identifier alphabet
  is ASCII letters, digits and underscore, with a letter or underscore
  first. Module names that differ only in case cannot coexist. Text values
  can contain Unicode.

The current language subset includes typed functions, integers, exact decimals, text,
booleans, lists, records, closed choices, optionals and results. The entry
can read bytes, decode UTF-8 strictly, decode a JSON record, update it,
and write UTF-8. Record decoding retains unknown JSON members with their
wire types. For a `text?` field, omission means absent and `""` means
present empty text. A JSON `null` in that field reports a schema error.
The built-in spellings and wire rules are provisional.

Run the regressions with the local runtime:

```text
machteld.exe test/application_compiler_test.tcl
machteld.exe test/application_compiler_semantics_test.tcl
machteld.exe test/application_compiler_io_test.tcl
```

On an archive-capable host, pass `-pack` to the I/O test to repeat the
same byte and error checks against a relocated archive. Run
`machteld.exe test/application_compiler_archive_test.tcl` to check
recompilation from bundled sources with only the executable and archive
in the delivery directory.

## Argument labels

Write a label before a parameter's local name when callers should identify
its role. The following function requires both labels, even though both
values have the same type.

```text
export fn .route(from $origin: text, to $destination: text) -> text =>
    $"$origin to $destination"
example .route(from: 'North', to: 'East') => 'North to East'
```

Calls supply each label in declaration order and with its exact spelling.
A parameter declared as `$value: text` takes an ordinary positional
argument. A signature can mix the two forms. Expressions evaluate once
from left to right. Generic and external function declarations use the
same syntax. The generated archive reference displays the required labels.
At the Tcl boundary the values occupy their declared positions, so a Tcl
caller uses `::application::routes::route North East` for this export in
module `routes`.

## Type aliases

`alias .titles = map<text,text>` gives an existing type a second name.
A parameter declared as `.titles` accepts a `map<text,text>`, and its
value can be passed directly to map operations. An alias can refer to a
later declaration. Aliases can name choices, records and other aliases.
The checker reports a cycle if following the aliases cannot reach a type.
This compiler stores a resolved type in at most 8,192 characters. A type
whose expanded generic arguments exceed that limit reports
`TYPE_EXPANSION_LIMIT` at its declaration.

Add `export` to expose an alias to other modules. For example, after
`import labels` a caller can write `.labels::titles`. Imports in the
module that declared the alias determine what its target name denotes.
Run `machteld.exe test/application_compiler_alias_test.tcl` for these
checks and their generated-Tcl behavior.

## Generic functions, records and choices

Declare type parameters after the name. Each parameter has a leading dot,
like other user-defined type names. The following function works for a
list of stations, a list of vehicles, or any other element type.

```text
export fn .first_or<.item>($items: list<.item>, $fallback: .item) -> .item {
    for $item in $items { return $item }
    return $fallback
}
```

The compiler checks the body once against its declared types, including
when the function has no callers. A body that adds one to an unconstrained
`.item` fails this check. Type arguments are normally inferred from the
value arguments. Use an explicit application such as `.first_or<text>(...)`
when writing out the type is clearer. Supply explicit arguments if the
ordinary arguments leave a parameter unknown, for example when it occurs
only in the result.

```text
export record .page<.item> { items: list<.item> }
export choice .selection<.item> {
    empty
    found(.item)
}
```

A `.page<.station>` retains its station fields all the way through a call.
Passing it as a `.page<.vehicle>` is a compile-time error. The constructor
`.selection::found($station)` infers `.station` from its payload. Write
`.selection<.station>::empty()` for the case with no payload. In a match
on a `.selection<.station>`, the `.selection::found($item)` arm receives
a station. Records, choices and functions can be exported across modules.
Their type parameters also appear in the archive's searchable application
reference.

A Tcl caller supplies the concrete types as its first argument to a
generic export. This call returns `found 007`.

```tcl
::application::pages::first {text} [dict create items {007 008}]
```

Supply one list element per parameter in declaration order. Use canonical names, such
as `text`, `list<int>` or `.pages::page<text>`. The generated command
checks both the descriptors and the values. Ordinary exported functions
keep their existing argument lists. A project's entry function has a
concrete signature.

To try both uses of the same page type, run the following from the
repository root.

```powershell
machteld.exe project test examples/typed-pages/project.dict
machteld.exe project pack examples/typed-pages/project.dict pages.machteld
'{"items":[{"name":"North"}]}' | machteld.exe pages.machteld stations
'{"items":[{"fleet_id":"007"}]}' | machteld.exe pages.machteld vehicles
machteld.exe project docs pages.machteld get fn/pages/first
```

## Distinct scalar types

Use a distinct type when two identifiers have the same representation but
belong to different domains. The following function accepts only a
`.product_id`. To call it with a text value, write
`.print_id(make<.product_id>('007'))`.

```text
distinct .product_id = text
fn .print_id($id: .product_id) -> text { return underlying($id) }
```

The declaration may use `text`, `int`, `decimal`, `bool`, `bytes`,
`instant` or `local_datetime`, including an alias for one of these types.
`make` and `underlying`
convert explicitly in either direction. An alias for a distinct type
retains its identity. A distinct type exported from another module keeps
the identity of its defining module even if a local type shares its name.

At a Tcl boundary the value uses the underlying scalar representation.
Decoding a typed record field validates that representation. Text-backed
IDs can be JSON object keys, and a map with numeric IDs sorts keys by
their exact numeric value. Use `underlying` before arithmetic on a
numeric ID. The declaration and conversion spellings are provisional.
Run `machteld.exe test/application_compiler_distinct_test.tcl` to check
construction, equality, module visibility and boundary behavior.

## Text literals

Single quotes preserve the text between them. For example, `'c:\temp'`
contains a backslash. Double quotes support escapes. In `"$price\n"`, the
dollar sign and the five letters `price` are literal, followed by a newline.

| Escape | Value |
| --- | --- |
| `\"`, `\\` | Quotation mark, backslash |
| `\n`, `\r`, `\t` | Line feed, carriage return, tab |
| `\0`, `\b`, `\f` | NUL, backspace, form feed |
| `\u{1f642}` | Unicode scalar from one to six hexadecimal digits, here 🙂 |

Both forms can span source lines. The compiler rejects unknown escapes,
surrogates and values above U+10FFFF. It reports a malformed escape at
its opening backslash. Run `machteld.exe test/application_compiler_text_test.tcl`
for executable examples.

Prefix a double-quoted string with `$` to insert a binding or an expression.
For example, with `$x` equal to `5`, `$"next=${$x + 1}"` produces `next=6`.
Use `$name` for a binding and `${...}` for an ordinary expression. Within
the braces, calls, quoted strings and `match` use their usual syntax.

```text
fn .caption($name: text, $count: int) -> text {
    return $"$name has ${$count + 1} items"
}
```

The current formatting rules preserve text, write integers and decimals
in canonical decimal notation and spell Booleans `true` or `false`. Use
`underlying($id)` to display a distinct scalar. Convert a structured value
explicitly by selecting the fields to display. Holes evaluate once, from
left to right. A propagated failure stops the string at that hole. Use
`\$` for a literal dollar sign in interpolated text. Ordinary double-quoted
strings keep all dollar signs literal. See
`test/application_compiler_interpolation_test.tcl` for executable examples.

## Decoding imported bytes

`decode_text($bytes, $encoding)` returns `result<text,problem>`. It
strictly decodes the original bytes using the named Tcl encoding. A
malformed sequence produces a problem with a zero-based `byteOffset`.
An unavailable encoding produces an `ENCODING` problem. Keep the byte value
when an import or a later review needs the original file.

`preview_text($bytes, $encoding)` uses replacement decoding. For example,
the three bytes `41 00 FF` in `utf-16le` produce `A` and U+FFFD in a
preview. Strict decoding reports the final incomplete byte at offset 2.
Use an explicit byte order such as `utf-16le` or `utf-16be` for portable
imports. A byte-order mark is retained as text when the codec decodes it
as U+FEFF. `decode_utf8($bytes)` remains the short form for strict UTF-8.

Use a name available on the running host, such as `utf-8` or `cp1252`.
The two tested hosts have a `cesu-8` decoder that can silently lose a
surrogate. Both builtins report that encoding as unavailable. Run
`machteld.exe test/application_compiler_decode_test.tcl` to exercise the
strict and preview cases.

## Calling Tcl commands

Declare the commands a module uses. Each declaration gives the function a
source name, typed parameters, a return type and a Tcl command prefix.

```text
extern fn .character_count($value: text) -> int = ['::string', 'length']
export fn .count_title($title: text) -> int { return .character_count($title) }

extern fn .format_title($title: text) -> text = ['::catalogue::title'] from 'catalogue'
```

Put the fully qualified Tcl command name first. Any remaining literal words
select a subcommand or supply fixed arguments. Each source argument becomes
one more Tcl word. For example, the first declaration calls
`::string length` and preserves spaces and brackets in the title.

Callers use the same argument and import rules as for an ordinary function.
The compiler can check the declaration and its callers on a machine where
the package is absent. At execution, `from` requires the named Tcl package
when the function is called. The wrapper checks the returned Tcl value
against the declared type. A Tcl command returning an empty value can have
return type `unit`. A function returning `result<T,problem>` accepts the
tagged Tcl lists `{ok value}` and `{err problemDictionary}`. For commands
with variable signatures, a short Tcl procedure can present a fixed
interface. Native exceptions and invalid returns report their declaration
location. A problem carrying its own valid source position retains it.
Run `machteld.exe test/application_compiler_extern_test.tcl` for boundary
examples and failure cases. The declaration spelling is provisional.

## Handling a typed result

Match a `result<T,E>` when the caller can recover from an expected failure.
The `ok` arm binds a value of type `T`. The `err` arm binds the declared
error type `E`, which can be another module's closed choice.

```text
choice .lookup_error {
    unavailable
    held(text)
}
fn .describe($lookup: result<text,.lookup_error>) -> text => match $lookup {
    ok($name) => $name
    err($reason) => match $reason {
        .lookup_error::unavailable => 'missing source'
        .lookup_error::held($why) => $"pending: $why"
    }
}
```

Write both `ok` and `err` exactly once, in either order. Use `err(_)`
when the error value itself is irrelevant. Grouped alternatives follow the
same binding rules as choice variants. For example, a `result<text,text>`
can match `ok($message) | err($message) => $message`. Use postfix `?`
when the caller should propagate the original typed failure.

## Grouping choice variants

A `match` on a closed choice must name every variant. Use `|` to give
several variants one action. Each alternative binds the same names with
the same types. They can come from different payload positions. A bare
`_` discards one payload field. `$_` binds a field to the ordinary name `_`.

```text
choice .label {
    plain(text)
    ranked(int, text)
}
fn .title($label: .label) -> text => match $label {
    .label::plain($s) | .label::ranked(_, $s) => $s
}
```

Adding another variant to `.label` gives a compile-time error at this
match until an arm covers it. The scrutinee and the selected action each
run once. The grouping and discard spellings are provisional. Run
`machteld.exe test/application_compiler_group_test.tcl` for more examples.

## Exact arithmetic

A literal such as `0.10` is an exact decimal. Addition, subtraction and
multiplication accept integers and decimals. Mixed operands produce a
decimal. For example, `0.1 + 0.2 == 0.3` is true. At a Tcl boundary a
decimal uses fixed-point text. The canonical spelling drops unnecessary
zeros, so `+007.500` becomes `7.5`. Declared decimal JSON fields accept
an integer or a fixed-point JSON number. Unknown members retain their
original wire value, including numbers written with exponents.

```text
fn .share($total: int, $count: int) -> result<decimal,problem> {
    return $total / $count
}
```

`5 / 2` succeeds with `2.5`. `1 / 3` returns a typed problem because
the quotient has no finite decimal representation. Division by zero also
returns a problem. Use `($total / $count)?` to propagate a failure.
`quotient(-5, 2)` succeeds with the integer `-2`, truncating toward zero.

`divide_rounded(a, b, places, mode)` rounds the exact quotient once to
the requested number of decimal places. `divide_rounded(2.345, 1, 2, 'half_even')`
yields `2.34` on success. `'half_away'` yields `2.35` and rounds a negative
tie away from zero as well. The mode and built-in names are provisional.
This implementation supports up to 100,000 places when materializing a
nonterminating quotient. Requesting more returns `ROUND_SCALE_LIMIT`.
An exact quotient already within the requested scale returns without padding.

Run `machteld.exe test/application_compiler_decimal_test.tcl` for the
source-level and generated-Tcl arithmetic checks.

## List values and lengths

Write `['007', '7']` for a `list<text>`. A list can span lines and have a
trailing comma. Its elements are evaluated once in source order. If an
element propagates a failure with `?`, later elements are skipped.
Each element must have the same type. A nested list can take its element
type from a sibling, as in `[[], [7]]`.

```text
fn .empty_names() -> list<text> => []
fn .lengths($word: text, $notes: list<text>) -> list<int> =>
    [len($word), len($notes)]
```

A parameter, return type or existing binding can supply the element type
of `[]`. A new local list binding needs a concrete element type. For
example, `$names := .empty_names()` declares an initially empty, mutable
`list<text>`. A Tcl caller receives an ordinary Tcl list with one word per
element, including empty strings and strings that contain spaces.

`len(value)` returns an `int`. It counts list elements, map entries, raw
bytes or Unicode code points, according to the type of its argument.
`len([])` is zero. Combining marks each count as a code point.

## Iteration

`for $value in $items` visits a list in order and binds one complete
element per iteration. An integer range contains its start and excludes its
end. Use `..=` to include both endpoints. For example, `2..5` visits
`2, 3, 4` and `2..=5` also visits `5`. Both forms are empty when the
start is greater than the end. Iteration computes the bounds once and
steps through exact integers without allocating a list of all values.

```text
fn .sum($start: int, $end: int) -> int {
    $values ::= $start..$end
    $total := 0
    for $i in $values {
        $total = $total + $i
    }
    return $total
}
```

The type of `$values` is `range<int>`. An exported function accepts that
type from Tcl as a three-element list of start, end and a closed flag
(`0` or `1`). Range equality and a JSON wire format are still open.
The iteration binding is fixed and visible only inside the body.
`break` and `continue` select the
innermost loop. Give a loop a label, as in `for .outer $item in $items`,
to target it from an inner loop with `break .outer` or `continue .outer`.
`while` tests a `bool` expression before every iteration. For example,
`while $remaining != 0 { $remaining = $remaining - 1 }` counts a positive
integer down to zero. Use `while .outer: .ready()` to label a loop whose
condition calls a function. `continue .outer` rechecks that condition.
`return` and a propagated failure still exit the function. Range and
label spellings are provisional.

Run `machteld.exe test/application_compiler_iteration_test.tcl` for the
iteration, scope and control-flow regressions.

## Ordered maps

`map<K,V>()` creates an empty map. `map_put` inserts or replaces a key
and returns the updated map. An existing key keeps its original position.
Keys can be `text`, `int`, `decimal` or `bool`. Key types match exactly.

```text
fn .titles($id: text, $title: text) -> map<text,text> {
    $titles := map<text,text>()
    $titles = map_put($titles, $id, $title)
    return $titles
}
```

`$titles[$id]` returns `none` for an absent key and `some('')` for a
present key with an empty title. `require_key($titles, $id)` returns a
typed result, with `MISSING_KEY` on failure. An update leaves earlier
copies intact, including maps nested inside another map.

`for $id in $titles` visits keys in insertion order. `sorted_keys($titles)`
returns a new list. Text sorts in case-sensitive Tcl string order, integers
and decimals in exact numeric order, and Booleans from false to true.
Map equality compares keys and values independently of insertion order
when the value type supports equality.

At an exported Tcl boundary, supply a dictionary. Keys that normalize to
the same typed key are rejected. For text keys, `007` and `7` remain
distinct. In a record, a text-keyed map uses a JSON object. The same
Unicode key compares equal whether it came from Tcl or JSON, including
keys containing U+0000. Encoding preserves those keys on both tested
hosts. A non-text key has no JSON object encoding in this edition. The
map built-in names are provisional.

Run `machteld.exe test/application_compiler_map_test.tcl` for the map
regressions.

## Local date-times and instants

Use `local_datetime` for the date and time recorded on a clock. Use
`instant` for a known point on the UTC timeline. They are distinct scalar
types. Both support equality, optional values and record fields. Convert
explicitly when crossing a text boundary.

| Operation | Result |
| --- | --- |
| `parse_local_datetime(text)` | `result<local_datetime,problem>` |
| `parse_instant(text)` | `result<instant,problem>` |
| `resolve_offset(local_datetime, int)` | `result<instant,problem>`, using minutes east of UTC |
| `resolve_zone(local_datetime, text)` | `result<list<instant>,problem>`, ordered from earliest to latest |
| `local_datetime_text(local_datetime)`, `instant_text(instant)` | Canonical `text` |

The input form is `YYYY-MM-DDTHH:MM:SS`, optionally followed by a dot and
one to nine fractional digits. An instant also requires `Z` or a known
numeric offset from `-14:00` through `+14:00`. Years range from 0001
through 9999 on the Gregorian calendar. Hours run from 00 through 23 and
seconds from 00 through 59. The unknown offset `-00:00` is rejected.
Syntax and calendar failures return `INVALID_LOCAL_DATETIME` or
`INVALID_INSTANT`. An out-of-range minutes argument gives `INVALID_OFFSET`.
Conversion outside the supported UTC years gives `INSTANT_RANGE`.

For example, `2026-10-25T02:30:00` with offset 120 resolves to
`2026-10-25T00:30:00.000000000Z`. With offset 60, it resolves to
`2026-10-25T01:30:00.000000000Z`.

With a location such as `Europe/Brussels`, call `resolve_zone` to find all
instants consistent with the clock reading. An ordinary reading returns one
instant. When a clock turns back, the same reading can have two instants.
A reading skipped when the clock jumps forward returns an empty list.
These are successful lookups. Keep the complete list until other evidence
identifies an occurrence. Match an independently recorded numeric offset
against the candidates if the source supplies both.

Zone names are case-sensitive and come from the time-zone tables bundled
with the Machteld executable. No machine time-zone setting is needed.
The tables cover named-zone lookups through 2099. Both the local date and
every candidate UTC date must fall within years 0001 through 2099.
Before a zone's first recorded transition, lookup uses its earliest listed
offset, which can include seconds of historical local mean time. Future
results reflect the rules in that executable. Keep its identity with
reproducible research. Unknown or malformed names give `INVALID_ZONE`.
`ZONE_RANGE` means the reading or a candidate exceeds the upper limit,
`INSTANT_RANGE` means a candidate precedes year 0001, and `ZONE_DATA`
means the host could not read its bundled rules.

Canonical instants always contain nine fractional digits and a final `Z`.
Canonical local date-times omit trailing fractional zeroes and the fraction
on whole seconds. Tcl arguments, JSON string fields and SQLite TEXT columns
typed as either scalar require its canonical form. For input with other
accepted spellings, read text and call the parser. A normal SQLite TEXT
index with BINARY collation orders canonical instants chronologically down
to a nanosecond, including the boundary between a whole and fractional second.

### Try a historical lookup

From the repository root, choose a fresh database filename and run these
commands using the integrated development host.

```powershell
machteld.exe examples/typed-time/create_sample.tcl timeline.db
machteld.exe project test examples/typed-time/project.dict
machteld.exe project pack examples/typed-time/project.dict timeline.machteld
'{"observed":"2026-10-25T02:30:00","offset_minutes":120}' | machteld.exe timeline.machteld timeline.db
'{"observed":"2026-10-25T02:30:00","offset_minutes":60}' | machteld.exe timeline.machteld timeline.db
'{"observed":"2026-10-25T02:30:00"}' | machteld.exe timeline.machteld timeline.db
'{"observed":"2026-10-25T02:30:00","zone":"Europe/Brussels"}' | machteld.exe timeline.machteld timeline.db
'{"observed":"2026-03-29T02:30:00","zone":"Europe/Brussels"}' | machteld.exe timeline.machteld timeline.db
```

The first two requests select different logs. The third keeps the reading
unresolved. With Brussels supplied, the autumn lookup returns both logs
and the spring lookup reports a nonexistent clock reading. The executable
examples also check conflicting evidence, adjacent one-nanosecond intervals
and the uncovered instant after an interval ends.

## Library-defined scoped resources

A library can associate a locally declared record, choice or distinct type
with a cleanup function. The function may be private or backed by a Tcl
`extern`. It receives the resource and returns `unit` or
`result<unit,problem>`. For example, a file library can declare
`resource .reader using .close` beside its distinct `.reader` type. The
resource declaration also appears on the exported type's archive reference
page. A declaration on a generic type applies to each concrete use.

```text
using $reader ::= .readers::open($path)? {
    return .readers::line($reader)
}
```

Cleanup runs once after successful acquisition, including on return, loop
exit, propagation and a Tcl error. Nested blocks release in reverse order.
Failed acquisition skips the block and its cleanup. Copying a handle does
not prolong the lifetime of the underlying resource.

A fallible closer requires an enclosing function returning
`result<…,problem>`. A cleanup failure replaces a successful exit. If
the block is already returning a problem, its `cleanupFailures` list
records each additional failure. A Tcl fault retains its original error
code and source location and carries secondary failures in its
`-appcompilercleanup` option. If an unexpected closer fault interrupts a
typed error whose payload is a user-defined type, the Tcl fault carries
the original result in `-appcompilerprimary`.

The `examples/scoped-reader` project reads the first line of a UTF-8 file
and closes it before returning, including when decoding fails.

```powershell
machteld.exe project pack examples/scoped-reader/project.dict preview.machteld
machteld.exe preview.machteld examples/scoped-reader/sample.txt
machteld.exe project docs preview.machteld get type/readers/reader
```

## Typed SQLite reads

Declare a record for one result row and supply a path to an existing
SQLite database. The arguments after the SQL text are bound values.

```text
record .observation {
    id: text
    note: text?
}

fn .active_at($db: text, $id: text, $at: int) -> result<.observation?,problem> =>
    sql_optional<.observation>($db,
        'SELECT entity AS id, note FROM observations
          WHERE entity = ?1 AND starts <= ?2 AND ?2 < ends',
        $id, $at)
```

| Read | Successful payload | Row count |
| --- | --- | --- |
| `sql_one<.row>(path, sql, ...)` | `.row` | Exactly one |
| `sql_optional<.row>(path, sql, ...)` | `.row?` | Zero or one |
| `sql_many<.row>(path, sql, ...)` | `list<.row>` | Any count, including zero |

Match an optional row with `none` and `some($row)`. Within a present row,
a nullable column can itself be `none` (SQL NULL) or `some('')` (empty
text). Use `ORDER BY` for a defined row order. `sql_many` collects the
selected rows in memory. Use a SQL filter or limit for a bounded read.

Passing a path opens the file read-only and closes the connection after the
query. Passing a transaction binding uses its existing connection. A relative
path resolves from the process working directory. SQLite
prepares a single read query against the actual database at execution time.
Checking and packing validate the declared types without opening the database.
Joins, common table expressions and FTS5 queries use ordinary SQLite syntax.
Use a single query when several tables must be read from the same snapshot.

Use positional placeholders `?` or `?N`. The first bound value occupies
slot 1. A repeated slot reuses the same value. Supply all slots through the
highest number, including gaps. For example, a query with only `?2` can
take the bindings `none, $id`. Output column labels must match the record
fields exactly, once each, even when the result is empty. Use `AS` to give
an expression or a joined column its field name. Column order may differ
from field order.

| Field or bound value | SQLite representation |
| --- | --- |
| `int` | Signed 64-bit INTEGER |
| `text` | TEXT, preserving such identifiers as `'007'` |
| `bytes` | BLOB |
| `bool` | INTEGER 0 or 1 |
| `decimal` | Binds as exact decimal TEXT. Reads accept decimal TEXT or INTEGER. |
| `instant`, `local_datetime` | Canonical TEXT in the temporal type's format |
| `T?` | SQL NULL or the storage class for `T` |

Type aliases and distinct scalars use their underlying representation.
For exact decimal storage, use a TEXT column. SQLite numeric affinity may
convert decimal text to a REAL, which the exact decoder rejects.
Unsupported field and argument types are compiler diagnostics. At runtime,
a read returns a typed problem with a stable code.

| Code | Meaning |
| --- | --- |
| `SQL_OPEN` | The existing database file could not be opened in the requested mode. |
| `SQL_UNAVAILABLE` | The host lacks the required SQLite binding or statement inspection. |
| `SQL_QUERY` | SQLite could not prepare or execute a permitted single read query. |
| `SQL_BIND` | Parameter count, spelling or value is invalid. |
| `SQL_COLUMNS` | Result labels differ from the declared row. |
| `SQL_TYPE` | A result value cannot be decoded as the field type. |
| `CARDINALITY` | The result has too many or too few rows for this read. |

### Run the history example

The following PowerShell commands use a host providing typed SQLite
evaluation, statement inspection and application archives. Run them from
the repository root with a fresh `history.db` filename. The setup script
creates sample data. The application itself only reads the database.

```powershell
machteld.exe examples/typed-history/create_sample.tcl history.db
machteld.exe tools/application_project.tcl test examples/typed-history/project.dict
machteld.exe tools/application_project.tcl pack examples/typed-history/project.dict history.machteld
'{"id":"007","at":31}' | machteld.exe history.machteld history.db
```

The result is `note=[ready]`. At 9 there is no row. At 10 the row has
a NULL note. At 20 the note is empty, and at 34 two observations overlap
and the lookup returns `CARDINALITY`. Copy the runtime, archive and database
to another directory to run the same query there.

## Scoped SQLite transactions

Open an existing database with a fixed binding and an explicit `?` for open
and lock failures. With an `items(id TEXT PRIMARY KEY)` table, this function
inserts two IDs together. If either ID is already present, both inserts
roll back.

```text
fn .insert_pair($path: text, $left: text, $right: text) -> result<unit,problem> {
    using $tx ::= sql_begin($path)? {
        sql_exec($tx, 'INSERT INTO items(id) VALUES (?1)', $left)?
        sql_exec($tx, 'INSERT INTO items(id) VALUES (?1)', $right)?
        sql_commit($tx)?
    }
    return ok(unit)
}
```

`sql_begin` acquires the SQLite writer lock with `BEGIN IMMEDIATE` and
enables foreign keys. `sql_exec` accepts one `INSERT`, `UPDATE` or
`DELETE` with bound values (including SQLite's upsert syntax).
Use `sql_one`, `sql_optional` or `sql_many` on the same binding to read
pending changes. A path read uses a separate snapshot. The scope binding
can appear only as the first argument of these SQL operations or
`sql_commit`. Both `sql_exec` and `sql_commit` return `result<unit,problem>`.
The typed write interface rejects schema changes, transaction commands,
multiple statements and `RETURNING` rows.

Only a successful explicit commit persists changes. Falling through the
closing brace, returning success early, propagating a problem, leaving
through a loop jump, or unwinding a fault closes an uncommitted transaction.
A failed write aborts the whole transaction, even if the caller handles
the error. A failed commit also closes it. A successful commit takes effect
immediately. Perform all validation before committing.

| Additional code | Meaning |
| --- | --- |
| `SQL_BEGIN` | SQLite could not start the transaction, for example because another writer holds the lock. |
| `SQL_COMMIT` | SQLite refused the commit, for example because of a deferred foreign key. |
| `SQL_TX_CLOSED` | A write, read or commit targeted a transaction that had already ended. |

### Importing observations from two sources

The project in `examples/typed-import` imports UTF-8 JSON into SQLite.
Each claim has a stable source and source-local ID, an entity, a field,
a text value and a validity interval measured in Unix seconds. The start
is inclusive and the end exclusive. The database stores the claim's JSON
alongside the searchable columns, including source-specific fields such
as a page number. Replaying the same claim adds zero rows. Reusing the
same source and ID with different content rejects the entire batch.

Run these commands in PowerShell from the repository root with a new
database filename and the development runtime on the command path. The
file redirections pass each UTF-8 batch to the application byte for byte,
including when running Windows PowerShell 5.1. The sample decodes each
batch in memory and commits it as one unit.

```powershell
machteld.exe examples/typed-import/create_sample.tcl observations.db
machteld.exe tools/application_project.tcl pack examples/typed-import/project.dict observations.machteld
cmd.exe /d /c "machteld.exe observations.machteld import observations.db < examples\typed-import\north.json"
cmd.exe /d /c "machteld.exe observations.machteld import observations.db < examples\typed-import\south.json"
'{"entity":"007","at":25}' | machteld.exe observations.machteld at observations.db
cmd.exe /d /c "machteld.exe observations.machteld import observations.db < examples\typed-import\invalid.json"
```

At 25, the query emits two JSON lines. North's claim `n1` says blue and
south's `s1` says green. Both carry `disputed: true` because their values
for the same field differ at that instant. At 30, only south's green claim
is active and its flag is false. The final command exits with status 1. Its
first claim was valid, but the second has an empty interval, so rerunning
the query gives exactly the same two claims. This disagreement policy belongs
to the example application. The compiler supplies the transaction and typed
SQL operations.

## Executable examples

Place an `example` immediately after the function it calls. A function may
have several examples. The checker verifies the call and its expectation.
The project driver's `test` command evaluates them and reports each failure
at its source location, followed by the total passed and failed.

```text
export fn .seconds($minutes: int) -> int => $minutes * 60
example .seconds(2) => 120

extern fn .hex($value: text) -> bytes = ['::binary', 'decode', 'hex']
export fn .decode_hex($value: text) -> result<text,problem> => decode_utf8(.hex($value))
example .decode_hex('4142') => 'AB'
example .decode_hex('4142ff') => error 'UTF8' { byteOffset = 2 }
```

A value expectation uses the language's equality rules. For a function
returning `result`, the value is the successful payload. An error expectation
requires a `result<T,problem>`. The example above checks the code and the byte
offset. To check only the code, write `=> error 'UTF8'`. Add `message = '…'`
to the field selection when exact wording is part of the contract. A missing
selected field fails. Other fields may vary. Examples can call private helpers
and imported functions. They execute with the project's declared Tcl packages.

## File-backed applications

The integrated host runs the driver directly as `machteld.exe project`.
Use `--project` to select it explicitly in a directory that also contains
a script named `project`. The checkout and editable archives retain their
standalone driver for use on earlier hosts.

The driver accepts a UTF-8 project dictionary. The following
manifest selects a module at `src/main.src` and an optional binary asset.
Paths are relative to the manifest. Module identifiers are case-sensitive.

```tcl
schema 1
edition 1
minApi 0.21
entry {app main}
modules {app src/main.src}
assets {assets/logo.png}
```

`schema` versions the manifest format. `edition` selects the source language
rules, and `minApi` sets the minimum Machteld version for building on a
Machteld host and for running the generated program. Remove the `assets`
line if the application has none. The manifest and its module table are Tcl
dictionaries read as data. Use list quoting for paths containing spaces.

### Migrating a Tcl/Tk project one file at a time

Choose exactly one startup form. With `entry {app main}`, a typed function
starts the application. With `tclEntry main.tcl`, the driver installs
the compiled exports and sources the original UTF-8 Tcl entry at global
scope. The Tcl file owns startup, Tk and the event loop. It appears in the
archive automatically. Declare other inputs as assets or modules.

```tcl
schema 1
edition 1
minApi 30
tclEntry main.tcl
modules {captions captions.src}
assets {lib/fields.tcl lib/captions.tcl lib/pkgIndex.tcl}
packageDirs {lib}
```

Begin with `modules {}` and the original Tcl files. Move one piece of
logic to a typed module, mark the function `export`, and forward the old
Tcl command to it. A wrapper with the old formal parameters preserves
Tcl introspection, wrong-argument errors and existing Tk callback names.

```tcl
proc ::cards::caption {field value} {
    tailcall ::application::captions::caption $field $value
}
```

Tcl calls exported functions with ordinary Tcl words. The boundary checks
typed arguments. Lists use Tcl lists, records use dictionaries, optional
values use `none` or `{some value}`, and results use `{ok value}` or
`{err problemDictionary}` for a function returning `result<T,problem>`.
A returned error result is data. Unexpected errors from a typed export
raise a Tcl error; its options preserve the Tcl error code and carry
`-appcompilerlocation` (module, line and column).

In the other direction, declare an `extern fn` for an existing Tcl command,
with a fixed command prefix and its types. Arguments preserve word boundaries
and the return value is checked. An extern runs in global scope. Tcl commands
that act on a caller's local variables, widget event substitutions, traces or
dynamic scripts generally need a Tcl adapter with explicit arguments. Either
language can supply an ordinary procedure used as a callback. Keep a GUI
callback short, as both languages share Tcl's event loop.

Run `machteld.exe project check project.dict` before packing. This checks
all typed modules and checks the Tcl entry's UTF-8 encoding and command
completeness. Tcl commands and lazy package indexes are exercised by running
the application. `project test` runs the typed examples and leaves the Tcl
entry idle. `project pack` and `project rebuild` preserve the originals.
The example in `examples/mixed-migration` compares an all-Tcl baseline,
one migrated module and a relocated archive, including an entry adapter
for programs that compare `argv0` with `info script`.

For a local pure-Tcl package, include its index and implementation in
`assets` and name the directory containing the index in `packageDirs`.
For example, a project exposing the `catalogue` package above can use
these two manifest entries.

```tcl
assets {plugins/catalogue/pkgIndex.tcl plugins/catalogue/catalogue.tcl}
packageDirs {plugins/catalogue}
```

Directories are added to Tcl's package search path in the order given.
The source driver resolves them beside the manifest. Packaged applications
resolve them inside the archive. Include any other scripts or data the
package reads in `assets`. Checking and packing preserve their bytes
without loading the package.

From the repository root, run the two-module text-length example with the
development driver. `Snow 雪` contains six characters. Both run commands
print `characters=6` followed by a newline.

```text
machteld.exe tools/application_project.tcl check examples/typed-text-length/project.dict
machteld.exe tools/application_project.tcl test examples/typed-text-length/project.dict
machteld.exe tools/application_project.tcl run examples/typed-text-length/project.dict "Snow 雪"
machteld.exe tools/application_project.tcl pack examples/typed-text-length/project.dict sample.machteld
machteld.exe sample.machteld "Snow 雪"
machteld.exe tools/application_project.tcl rebuild sample.machteld rebuilt.machteld
```

`check` validates every declared input and the entry signature without
starting the app. `run` forwards each argument after the manifest, including
empty arguments, and the application inherits standard input and output.
`test` checks the whole project before running its examples. It leaves the
application entry idle, except for any explicit example calling that function.
`check`, `pack` and ordinary application startup leave examples unexecuted.
`pack` and `rebuild` require an archive-capable host with SQLite FTS5. A working archive
is replaced only after the replacement has been built and checked.

`check --json` writes one UTF-8 JSON document to standard output. A clean
check exits with status 0 and prints an empty `diagnostics` array. A failed
check exits with status 1. Each compiler diagnostic contains `code`,
`message` and a `node` with the logical `module`, `line`, `column`,
`endLine` and `endColumn`. Source positions are one-based. The end is
exclusive. A project error without a source position has a null `node`.

```text
machteld.exe tools/application_project.tcl check --json examples/typed-text-length/project.dict
```

```json
{"schema":1,"ok":true,"diagnostics":[]}
```

The archive contains the generated `main.tcl` with its source map, the
compiler under `compiler/`, and the original manifest at
`project/inputs/application.dict`. The declared source and asset files keep
their relative paths and exact bytes under `project/inputs/`. The path
`application.dict` in that directory is reserved for the manifest.

### Reading the offline application reference

Each new archive includes `project/reference.db`. It contains one Markdown
page per exported function or type, with its source-level signature.
Consecutive `##` lines directly above the declaration supply the page's
Markdown description. Function pages also display their exact source
examples. Private functions' examples still run in project tests.

```text
machteld.exe tools/application_project.tcl docs sample.machteld search "character count"
machteld.exe tools/application_project.tcl docs sample.machteld get fn/textutil/describe
machteld.exe tools/application_project.tcl docs --runtime get machteld/command/docs 0 1000
```

`search QUERY [LIMIT]` uses SQLite FTS5 and returns one page ID per line.
The default limit is 50 and the maximum is 200. Application IDs are
case-sensitive and use `fn/MODULE/NAME` or `type/MODULE/NAME`.
`get ID [OFFSET [LIMIT]]` returns a Markdown slice measured in characters.
The default offset is zero and the default limit is 32,768. The maximum
limit is 1,048,576. Use `--runtime` on a host carrying the Machteld
reference to query its manual with the same commands. Reading an application
reference verifies the archive and reads its database without loading any of
the application's Tcl or starting its examples. Rebuild an older archive
with the current compiler to generate its reference.

A recipient with only the archive and an archive-capable `machteld.exe`
can also rebuild it. From their directory, start `machteld.exe` in a
terminal and enter this Tcl at the prompt. The new archive uses the
compiler bundled with the application.

```tcl
set root [zipfs mount sample.machteld build]
try {
    ::machteld::ArchiveEntry $root
    source -encoding utf-8 [file join $root compiler compiler.tcl]
    ::appcompiler::project::pack [file join $root project inputs application.dict] rebuilt.machteld
} finally {zipfs unmount $root}
```

### Editing a delivered application

From a directory containing `machteld.exe` and `sample.machteld`, start
`machteld.exe` and enter the following at its Tcl prompt. Use fresh names
for the two destination directories. `working-source` receives the project
manifest, sources, assets and local Tcl packages. `local-compiler` receives
the compiler, its driver and this guide.

```tcl
set root [zipfs mount sample.machteld build]
try {
    ::machteld::ArchiveEntry $root
    file copy [file join $root project inputs] working-source
    file copy [file join $root compiler] local-compiler
} finally {zipfs unmount $root}
exit
```

Edit the files in `working-source`. From a terminal, check the edits, run
the source project and build a new archive. These commands use the extracted
compiler and work after the original archive has been put away.

```text
machteld.exe local-compiler/driver.tcl check --json working-source/application.dict
machteld.exe local-compiler/driver.tcl test working-source/application.dict
machteld.exe local-compiler/driver.tcl run working-source/application.dict "Snow 雪"
machteld.exe local-compiler/driver.tcl pack working-source/application.dict revised.machteld
machteld.exe local-compiler/driver.tcl docs revised.machteld get fn/textutil/describe
machteld.exe revised.machteld "Snow 雪"
```

Run `machteld.exe test/application_compiler_project_test.tcl` to check
the file-backed driver. Add `-pack` on an archive-capable host to include
relocation, source-free rebuild and the two-file terminal workflow.
