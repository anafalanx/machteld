---
type: guide
title: Packaging
description: Direct Machteld entries and standalone console or GUI tools.
tags: [machteld, wrap, zipfs, deployment]
---

# Packaging

Machteld has one program boundary and two deployment forms.

## Direct entry

```text
machteld.exe program.tcl argument ...
```

The program file must be readable UTF-8 and begin with a literal `package require
machteld` command (optionally with a literal version or `-exact`). `.tcl` is a
conventional extension, not a requirement. The host parses that
command before Tcl evaluates the file. The rest of the file is ordinary Tcl and
receives the remaining arguments in `argv`.

This opt-in prevents an arbitrary `.tcl` file from accidentally acquiring
machine-control authority. It also makes the dependency visible to an editor,
reviewer, packager, and the Tcl package system in the same spelling.

## Wrapped entry

```text
machteld.exe wrap app.tcl -o app.exe
machteld.exe wrap appdir -o app.exe --console
machteld.exe wrap appdir -o app.exe --entry src/start.tcl --gui
```

The input is either one opted-in entry file or a directory. For a directory,
`main.tcl` is the only default; `--entry` names a different file below that
directory. Absolute, volume-relative, empty, and `..`-escaping entry paths are
refused. The application is stored below archive-root `app/`. A generated,
opted-in root launcher sources the selected entry at its original relative path,
so `[info script]` and sibling-file lookups keep their ordinary meaning.

Hidden files are included. Empty directories are not represented in the zipfs
image, and sibling names that differ only by case are refused because the
portable staging tree is case-insensitive. Because the application has its own
archive subtree, names such as `docs`, `basekit`, and `tcl_library` remain
available to application authors. A directory containing a junction, symlink, other
name-surrogate reparse point, or an unreadable traversal row is refused rather
than followed outside the input or copied recursively. The source, entry, and
output containment checks use canonical Windows identity/path facts, not lexical
normalization alone. Do not mutate an input tree while `wrap` is reading it.

The staged entry is checked with the exact parser used by direct startup, so the
bytes selected for the executable—not merely an earlier source pathname—must opt
in. `wrap` builds in a randomly named directory on the destination volume and
publishes only the completed candidate. Cleanup of interrupted work is best
effort and is not part of the publication guarantee. Existing output is replaced
with the native Windows atomic-replacement primitive; a failure leaves the
previous output intact. After replacement has committed, cleanup of its randomly
named recovery backup is best effort; a filesystem refusal can leave that old
backup beside the successfully published executable, without turning success
into a misleading failure.

## What is inside

A wrapped executable contains:

- the selected console or GUI basekit;
- the full Machteld 0.12.0 prelude and public palette;
- the Tcl and Tk script libraries;
- Machteld's Apache 2.0 license and the required Tcl/Tk distribution notices
  under `licenses/`;
- the complete indexed Machteld, Tcl 9, and Tk 9 reference corpus;
- the application entry and assets in zipfs;
- the same native Windows core and statically linked SQLite store.

There is no prelude-free or reduced-capability option. `package require machteld`
inside a wrapped tool returns 0.12.0, `manifest` describes the same API, and
binary-safe `store` has the same behavior and five-second busy timeout. Wrapping
does not change the programmatic machine-control API. The reference corpus is
copied so `docs`, `help`, and the reserved `--machteld-docs` host route remain
self-contained. Only basekits are distribution-only: a wrapped tool cannot run
`wrap` again.

`--console` is the default and provides standard channels. `--gui` selects the
Windows GUI subsystem and does not create a console; use `log -file` or a Tk
dialog for diagnostics. Tk is on demand in a console tool and initialized during
startup in a GUI tool; requiring it explicitly keeps source portable between the
two:

```tcl
package require machteld 0.12.0
package require Tk
```

No compiler and no installed Tcl are needed to run the result.
