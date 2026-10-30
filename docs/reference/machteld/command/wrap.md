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
wrap input -o output.exe ?--entry relativePath? ?--console|--gui? ?--with-docs? ?--manifest file? ?--plan?
```

## Arguments and options

`input` is one opted-in file or a directory. A directory defaults to
`main.tcl`; `--entry` selects another relative file below it and is invalid for
a single-file input. `-o` is required. `--console` is the default;
`--gui` selects the Windows GUI subsystem. The staged entry's first executable
command must be a literal `package require machteld` form.

`--manifest FILE` selects an explicit inventory for directory input. The file
is UTF-8 Tcl dictionary data, never a script. It requires `schema 1` and `files`.
Unknown or duplicate keys are refused, `metadata` among them: application
metadata is not part of this version.
The manifest is limited to 1 MiB and selects 1–10000 regular files. Paths are
relative to `input`, use forward slashes, and name exact files, not directories
or glob patterns. The selected entry must be listed. Files are not added merely
because they are hidden, imported by a script, or beside a selected file.

```tcl
schema 1
files {main.tcl lib/jobs.tcl assets/.theme}
```

Use a dedicated application staging directory, not a repository root. Without
`--manifest`, the existing whole-directory behavior remains: every file,
including hidden files, is selected. There is no implicit secret-file filter.
With a manifest, deliberately selected hidden assets remain legitimate.

`--plan` validates and returns the selected application inventory without
creating a work directory or changing the output. `-o` is still required, and
the output is checked as the wrap would check it. Preview is not a lock on the
input; the actual wrap performs fresh validation.

The tool keeps its basekit's Windows resources: the console or GUI host's
VERSIONINFO, with Machteld's identity. Application identity, a tool's own
name, version information, authorship and icon, is not part of this version.
Wrapping does not sign the application.

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

With `--plan`, returns an inert dict instead of publishing. The same record is
embedded as archive-root `app-info.dict`: schema, entry, host kind, documentation
choice, runtime identity, and a deterministic file inventory with sizes and
SHA-256 hashes. Build-machine paths and wall-clock timestamps are omitted.
This is a consistency record, not a signature. Runtime `build-info.dict`, when
present, is retained separately and unchanged.

## Errors

Raised codes are `WRAP badvalue`, `WRAP notfound`, `WRAP optin`,
`WRAP oserror`, `WRAP unsupported`, and `WRAP usage`. `unsupported` means the
current host intentionally carries no basekits (wrapped tools cannot recursively
wrap), or `--with-docs` was requested but the reference pack is unavailable or
invalid. Pre-publication failures leave the destination unchanged. A rare
replacement failure followed by failed restoration can leave the old output at
the recovery-backup path reported by `WRAP oserror`, not its original pathname.

## Lifetime and timeouts

Wrapping stages in a randomly named directory on the output volume, builds the
candidate, then uses native atomic replacement. Cleanup of interrupted work and
post-commit recovery backup deletion is best effort. There is no timeout.
Selected source identities and bytes and the manifest are checked
again before publication. Staged assets and the completed ZIP payload are
verified against their inventories. Detected changes fail without publishing;
these checks do not make an actively hostile, concurrently modified filesystem
an authority sandbox or a transactionally locked source snapshot.

## Examples

```tcl
wrap app.tcl -o app.exe --console
wrap appdir -o viewer.exe --entry src/main.tcl --gui
wrap app.tcl -o documented-app.exe --with-docs
wrap app-stage -o tool.exe --manifest app.dict --plan
wrap app-stage -o tool.exe --manifest app.dict
```

## Constraints

Selected directory input preserves hidden files but not empty directories. Sibling names
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
