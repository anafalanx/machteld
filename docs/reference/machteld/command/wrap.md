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
wrap input -o output.exe ?--entry relativePath? ?--console|--gui? ?--with-docs?
```

## Arguments and options

`input` is one opted-in file or a directory. A directory defaults to
`main.tcl`; `--entry` selects another relative file below it and is invalid for
a single-file input. `-o` is required. `--console` is the default;
`--gui` selects the Windows GUI subsystem. The staged entry's first executable
command must be a literal `package require machteld` form.

The built-in Machteld/Tcl/Tk reference corpus is omitted by default.
`--with-docs` takes no value and includes the complete verified reference pack.
It does not select individual products or pages. The distribution executable
itself always carries the reference; application documentation and assets,
runtime libraries, and required license notices are included independently of
this option.

## Results

Returns the normalized path of the atomically published executable. The tool
contains the application under `app/`, Machteld/Tcl/Tk, static SQLite, and
required licenses. With `--with-docs`, it also contains the complete embedded
reference pack. It requires no installed Tcl or compiler at runtime.

## Errors

Raised codes are `WRAP badvalue`, `WRAP notfound`, `WRAP optin`,
`WRAP oserror`, `WRAP unsupported`, and `WRAP usage`. `unsupported` means the
current host intentionally carries no basekits (wrapped tools cannot recursively
wrap), or `--with-docs` was requested but the reference pack is unavailable or
invalid. Publication failure leaves an existing output intact.

## Lifetime and timeouts

Wrapping stages in a randomly named directory on the output volume, builds the
candidate, then uses native atomic replacement. Cleanup of interrupted work and
post-commit recovery backup deletion is best effort. There is no timeout.

## Examples

```tcl
wrap app.tcl -o app.exe --console
wrap appdir -o viewer.exe --entry src/main.tcl --gui
wrap app.tcl -o documented-app.exe --with-docs
```

## Constraints

Directory input includes hidden files but not empty directories. Sibling names
differing only by case are refused. Junctions, symlinks, other name-surrogate
reparse points, unreadable traversal rows, escaping `..`, and output contained
inside the input are refused. The output parent directory must already exist.
Do not mutate the input tree while it is copied.
Wrapped applications own ordinary application arguments; the reserved
`--machteld-docs` host route remains available with or without the reference.
Without it, corpus queries report `DOCS unsupported` (in the usual error envelope
with `--json`), and `help` queries report `HELP unsupported`. Bare `help` explains
the omission; `docs schema` and `manifest` remain available. Application-provided
help is unaffected. GUI host queries still require `--output FILE` except for
extraction. Basekits are never copied recursively, even with `--with-docs`.

## See also

`machteld/guide/packaging`, `machteld/command/docs`,
`machteld/guide/contract`.
