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

The current language subset includes typed functions, integers, text,
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
