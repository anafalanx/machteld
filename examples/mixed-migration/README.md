# Migrate one Tcl package at a time

This example keeps the Tcl entry, the Tk refresh button and the field-name
catalogue. Only the caption formatter moves to typed source.

1. The existing application requires `cards::captions` and calls
   `::cards::caption $field $value`. Its original implementation is in
   [before/captions.tcl](before/captions.tcl).
2. [captions.src](captions.src) exports the replacement. Its `extern`
   declaration calls the existing `::cards::fieldName` in the Tcl package
   `cards::fields`. A Tcl error from that command keeps its error code as
   it crosses back through the typed function to the Tcl caller.
3. [lib/captions.tcl](lib/captions.tcl) keeps the original Tcl procedure
   signature and forwards its arguments with `tailcall`. Even `info args`
   and the wrong-argument diagnostic keep their original behavior. The
   project manifest selects `main.tcl` as `tclEntry` and lists the converted
   module, the remaining Tcl files and their package directory.

From the repository root, run the source examples and the application with
the development runtime on the command path.

```powershell
machteld.exe project test examples/mixed-migration/project.dict
machteld.exe project run examples/mixed-migration/project.dict id 007
machteld.exe project pack examples/mixed-migration/project.dict cards.machteld
machteld.exe cards.machteld id 007
```

Both runs print `Inventory ID: 007`. The headless entry schedules its
refresh command through Tcl's event loop. On a desktop, launch
`machteld.exe cards.machteld --gui shelf A-17` to use the same command as
a real `ttk::button -command`. The label starts at `Shelf: A-17`.

For a Tcl-only starting point, use `modules {}`, put the original
`before/captions.tcl` at `lib/captions.tcl` in a copy of the sample, and
leave the other files alone. You can run its `main.tcl` directly. During
migration, run the mixed source through the project driver so it loads
the compiled commands before the Tcl entry requires the package.

## Existing startup guards

For a source project, `argv0` and `info script` both identify the Tcl entry
file. In an archive, `argv0` identifies the archive and `info script`
identifies the current script inside it. Resolve bundled data and sibling
scripts relative to `[file dirname [info script]]`. The process working
directory remains the caller's.

An existing sourceable application may guard its startup with
`if {[file normalize [info script]] eq [file normalize $::argv0]} { ... }`.
Keep that file intact. Select a short `startup.tcl` as the project entry,
include the original script in `assets`, and call its startup procedure
once. This adapter calls an original procedure taking the argument list.

```tcl
package require machteld
source -encoding utf-8 [file join [file dirname [info script]] legacy.tcl]
::legacy::main $::argv
```

Run `machteld.exe test/application_compiler_migration_test.tcl -pack` to
compare the original, the mixed source, a relocated archive and a rebuild
from the delivered sources. The test also runs the startup adapter through
both the source and archive paths.
