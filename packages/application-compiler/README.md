# Application compiler

This development package compiles typed source modules to Tcl 9. It runs in
ordinary Tcl or in a Machteld Tcl script. The caller supplies a dictionary of
logical module names and source strings, so source files can also come from
a mounted application archive.

```tcl
package require machteld
lappend auto_path [file join [file dirname [info script]] packages application-compiler]
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

The type of `$values` is `range<int>`. The iteration binding is fixed
and visible only inside the body. `break` and `continue` select the
innermost loop. Give a loop a label, as in `for .outer $item in $items`,
to target it from an inner loop with `break .outer` or `continue .outer`.
`return` and a propagated failure still exit the function.
Range and label spellings are provisional.

Run `machteld.exe test/application_compiler_iteration_test.tcl` for the
iteration, scope and control-flow regressions.

## File-backed applications

The development driver accepts a UTF-8 project dictionary. The following
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

From the repository root, run the development driver with the local executable.

```text
machteld.exe tools/application_project.tcl check project.dict
machteld.exe tools/application_project.tcl run project.dict argument
machteld.exe tools/application_project.tcl pack project.dict sample.machteld
machteld.exe sample.machteld argument
machteld.exe tools/application_project.tcl rebuild sample.machteld rebuilt.machteld
```

`check` validates every declared input and the entry signature without
starting the app. `run` forwards each argument after the manifest, including
empty arguments, and the application inherits standard input and output.
`pack` and `rebuild` require an archive-capable host. A working archive
is replaced only after the replacement has been built and checked.

The archive contains the generated `main.tcl` with its source map, the
compiler under `compiler/`, and the original manifest at
`project/inputs/application.dict`. The declared source and asset files keep
their relative paths and exact bytes under `project/inputs/`. The path
`application.dict` in that directory is reserved for the manifest.

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

Run `machteld.exe test/application_compiler_project_test.tcl` to check
the file-backed driver. Add `-pack` on an archive-capable host to include
relocation, source-free rebuild and the two-file terminal workflow.
