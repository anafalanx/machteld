---
id: machteld/command/wrap
type: command
title: wrap
summary: Package an opted-in Machteld entry and assets as one standalone console or GUI executable.
commands: wrap
---

# wrap

## Synopsis

```tcl
wrap input -o output.exe ?--entry relativePath? ?--console|--gui?
```

## Arguments and options

`input` is one opted-in file or a directory. A directory defaults to
`main.tcl`; `--entry` selects another relative file below it and is invalid for
a single-file input. `-o` is required. `--console` is the default;
`--gui` selects the Windows GUI subsystem. The staged entry's first executable
command must be a literal `package require machteld` form.

## Results

Returns the normalized path of the atomically published executable. The tool
contains the application under `app/`, Machteld/Tcl/Tk, static SQLite, required
licenses, and the complete embedded reference pack. It requires no installed
Tcl or compiler at runtime.

## Errors

Raised codes are `WRAP badvalue`, `WRAP notfound`, `WRAP optin`,
`WRAP oserror`, `WRAP unsupported`, and `WRAP usage`. `unsupported` means the
current host intentionally carries no basekits (wrapped tools cannot recursively
wrap). Publication failure leaves an existing output intact.

## Lifetime and timeouts

Wrapping stages in a randomly named directory on the output volume, builds the
candidate, then uses native atomic replacement. Cleanup of interrupted work and
post-commit recovery backup deletion is best effort. There is no timeout.

## Examples

```tcl
wrap app.tcl -o app.exe --console
wrap appdir -o viewer.exe --entry src/main.tcl --gui
```

## Constraints

Directory input includes hidden files but not empty directories. Sibling names
differing only by case are refused. Junctions, symlinks, other name-surrogate
reparse points, unreadable traversal rows, escaping `..`, and output contained
inside the input are refused. The output parent directory must already exist.
Do not mutate the input tree while it is copied.
Wrapped applications own ordinary application arguments; the reserved
`--machteld-docs` host route provides universal reference access.

## See also

`machteld/guide/packaging`, `machteld/command/docs`,
`machteld/guide/contract`.
