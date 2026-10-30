---
type: guide
title: Packaging
description: Direct Machteld entries and standalone console or GUI tools.
tags: [machteld, wrap, zipfs, deployment]
---

# Packaging

Machteld has one program boundary and two deployment forms.

The workflow below describes machteld 22, in preparation and not yet released.
The historical signed release is unchanged and does not provide the newer
`--manifest`, `--plan`, or application-identity features. Inspect the selected executable's `manifest` and artifact identity
before selecting packaging options.

## Direct entry

```text
machteld.exe program.tcl argument ...
```

The program file must be readable UTF-8 and begin with a literal `package require
machteld` command (optionally with a literal version or `-exact`). `.tcl` is a
conventional extension, not a requirement. The host parses that
command before evaluation. For a native startup file, validation and evaluation
use the same captured file contents. The rest of the file is ordinary Tcl and
receives the remaining arguments in `argv`.

This opt-in makes the dependency visible to an editor, reviewer, packager, and
the Tcl package system, and refuses accidental entry through unrelated scripts.
It does not grant, reduce, or isolate Windows authority. Scripts and loaded DLLs
are trusted code running with the user's permissions; ordinary Tcl file and
process commands remain available. It is not a sandbox or a safe way to execute
an untrusted program.

## Wrapped entry

```text
machteld.exe wrap app.tcl -o app.exe
machteld.exe wrap appdir -o app.exe --console
machteld.exe wrap appdir -o app.exe --entry src/start.tcl --gui
machteld.exe wrap appdir -o documented-app.exe --with-docs
machteld.exe wrap app-stage -o app.exe --manifest app.dict --plan
machteld.exe wrap app-stage -o app.exe --manifest app.dict
```

The input is either one opted-in entry file or a directory. For a directory,
`main.tcl` is the only default; `--entry` names a different file below that
directory. Absolute, volume-relative, empty, and `..`-escaping entry paths are
refused. The application is stored below archive-root `app/`. A generated,
opted-in root launcher sources the selected entry at its original relative path,
so `[info script]` and sibling-file lookups keep their ordinary meaning.

Without a manifest, all files, including hidden files, are included. Empty
directories are not represented in the zipfs
image, and sibling names that differ only by case are refused because the
portable staging tree is case-insensitive. Because the application has its own
archive subtree, names such as `docs`, `basekit`, and `tcl_library` remain
available to application authors. A directory is refused rather than followed
outside the input or copied recursively if traversal encounters a junction,
symlink, any other name-surrogate reparse point, or an unreadable row. The
source, entry, and output containment checks use canonical Windows identity/path
facts, not lexical normalization alone. Do not mutate an input tree while
`wrap` is reading it.

The staged entry is checked with the exact parser used by direct startup, so the
bytes selected for the executable—not merely an earlier source pathname—must opt
in. `wrap` builds in a randomly named directory on the destination volume and
publishes only the completed candidate. Cleanup of interrupted work is best
effort and is not part of the publication guarantee. Existing output is replaced
with the native Windows atomic-replacement primitive. Pre-publication failures
leave the destination unchanged. If Windows replacement fails and the old
destination cannot be restored to its original name, `WRAP oserror` reports a
recovery-backup path; recover the previous bytes there rather than assuming the
original pathname still exists. After replacement has committed, cleanup of its randomly
named recovery backup is best effort; a filesystem refusal can leave that old
backup beside the successfully published executable, without turning success
into a misleading failure.

## Deliberate payload selection

Use a dedicated application staging directory and an explicit inventory. Do not
point `wrap` at a repository root: the legacy whole-tree form includes `.git`,
credentials, local databases, and other unrelated files if they are present.
There is no heuristic secret scanner or blanket hidden-file exclusion. A
legitimate hidden theme or configuration asset can be explicitly selected.

The `--manifest` input is UTF-8 Tcl dictionary **data**, not sourced Tcl code:

```tcl
schema 1
files {main.tcl lib/jobs.tcl assets/.theme}
metadata {
    name {My Project Tool}
    version 1.0
    description {Local project administration}
}
```

`files` names 1–10000 regular files relative to the input directory. It does not
expand globs, recursively select directories, discover `source`/`package require`
dependencies, or automatically add the entry. List the selected entry yourself.
Paths cannot escape the input. Unknown or duplicate manifest keys, colliding
names, and missing assets fail before publication. The file is limited to 1 MiB.
An omitted or empty metadata dict keeps the existing basekit Windows resources.

For example, from this checkout in PowerShell, prepare a fresh Inspector stage:

```powershell
$stage = New-Item -ItemType Directory -Path .\out\inspector-stage -ErrorAction Stop
foreach ($name in @('main.tcl','launch.tcl','model.tcl','view.tcl','inspect.tcl')) {
    Copy-Item -LiteralPath (Join-Path .\examples\project-inspector $name) -Destination $stage.FullName
}
.\out\machteld.exe wrap $stage.FullName -o .\out\inspector.exe --gui --manifest .\examples\project-inspector\app.dict --plan
.\out\machteld.exe wrap $stage.FullName -o .\out\inspector.exe --gui --manifest .\examples\project-inspector\app.dict
```

The first command creates a new stage rather than merging with an old one. On
later runs, use another fresh stage or deliberately review the existing one.
`--plan` writes neither a work directory nor an executable. It returns the exact
application record that a wrap of unchanged inputs will embed as archive-root
`app-info.dict`: selected file paths, byte counts, SHA-256 hashes, entry, host,
documentation choice, application metadata, and separate runtime identity.
It still requires `-o`, whose basename supplies the application's internal and
original filenames. The actual wrap revalidates the selection; preview does not
reserve or lock files.

Selected file identities and hashes, manifest bytes, and icon bytes are checked
again before publishing. Staged content and the completed ZIP inventory are
verified too. Whole-tree wrapping additionally checks for additions/removals.
Detected source changes, interrupted candidate creation, malformed resources,
or destination contention do not replace the previous good executable. No
claim is made of a transactionally locked snapshot of a hostile mutable source
tree: keep build inputs stable while wrapping.

The inventory contains no absolute build paths or timestamps. Hashes detect
inconsistency, not malicious replacement of an unsigned executable. Inspect an
existing application's record with ordinary zipfs operations or from its entry:

```tcl
set path [file join //zipfs:/app app-info.dict]
set ch [open $path r]
fconfigure $ch -encoding utf-8
try { set application [read $ch] } finally { close $ch }
set selected [dict get $application files]
```

Never `source` an inventory. The archive's `app/` subtree holds application
assets; `app-info.dict` is beside it at the runtime archive root.

## What is inside

A wrapped executable contains:

- the selected console or GUI basekit;
- the full Machteld 22 prelude and public palette;
- the Tcl and Tk script libraries;
- Machteld's Apache 2.0 license and the required Tcl, Tk, zlib, LibTomMath, and
  yyjson distribution notices under `licenses/`;
- the application entry and assets in zipfs;
- the same native Windows core, statically linked public-domain SQLite store,
  Tcl's bundled zlib/LibTomMath code, and MIT-licensed yyjson reader.

There is no prelude-free or reduced machine-control runtime option. `package
require machteld` inside a wrapped tool returns 22, `manifest` describes the
same API, and binary-safe `store` has the same behavior and five-second busy
timeout. Wrapping does not change the programmatic machine-control API.

The built-in reference corpus is omitted from wrapped tools by default. The
`--with-docs` flag includes the complete indexed Machteld, Tcl 9, and Tk 9
reference after verifying the pack; it is not a partial-reference selector.
Machteld itself always carries the full reference. Application documentation
and assets remain under `app/` regardless of this flag, and all runtime
libraries and license notices listed above remain included.

Without the built-in corpus, `docs schema` still works and `manifest` still
describes the runtime. Corpus queries report `DOCS unsupported`; a `help` query
reports `HELP unsupported`, while bare `help` explains how to use the full
same-version Machteld executable or package with `--with-docs`. A wrapped
application's own help and ordinary arguments are unaffected. The reserved
`--machteld-docs` host route remains available: corpus queries return the usual
structured error envelope with `--json`. GUI hosts still require `--output FILE`
except for extraction. With `--with-docs`, `docs`, `help`, and that host route
provide the full offline reference.

Basekits are distribution-only: a wrapped tool cannot run `wrap` again, with or
without the reference pack.

The main Machteld host carries Windows VERSIONINFO derived from its canonical
version: product and file version `22` (22.0.0.0 as Windows' fixed version),
the Machteld product identity, and Vincent Vercauteren as author, publisher,
and copyright holder. Wrapped programs inherit that basekit metadata unless
they explicitly supply application metadata as described below. Tcl's embedded configuration points to the self-mounted
payload; build-machine paths are absent from the artifact.

`--console` is the default and provides standard channels. `--gui` selects the
Windows GUI subsystem and does not create a console; use `log -file` or a Tk
dialog for diagnostics. Tk is on demand in a console tool and initialized during
startup in a GUI tool; requiring it explicitly keeps source portable between the
two:

```tcl
package require machteld 22-
package require Tk
```

No compiler and no installed Tcl are needed to run the result.
That statement covers the bundled runtime, not undeclared external packages or
DLL dependencies. The [contract](contract.md) defines the Windows target policy;
running on a development machine is not acceptance evidence for every target.
Wrapping itself is synchronous and can take time to hash, copy, and verify
assets; do not perform a large wrap inside a responsive Tk callback.

## Application identity

An explicit manifest metadata dict must provide `name` and `version`.
`description` defaults to the name. `author`, `publisher`, and `copyright` are
optional and default to empty, never inferred from Machteld, the source folder,
Git settings, or the current account. `icon` optionally names a Windows `.ico`
file relative to the manifest's directory (or an absolute path). It is not
automatically copied into `app/`; list it as an asset too if the application
needs to read it at runtime.

```tcl
metadata {
    name {Project Inspector}
    description {Read-only directory inspection}
    version 1.0
    author {Vincent Vercauteren}
    publisher {Vincent Vercauteren}
    copyright {Copyright 2026 Vincent Vercauteren}
    icon assets/inspector.ico
}
```

This fragment belongs inside a complete manifest, and its icon must exist.
Ordinary wrapping requires no compiler, PowerShell resource helper, or external
resource editor. A small built-in native stamper validates the supplied Unicode,
numeric version, and icon before changing the disposable bare-host copy. It
preserves other host resources, then the ZIP payload is attached and verified.
It does not modify the running host or patch an already signed executable.

Versions have one to four decimal components, each in 0–65535, at most 23
characters. Windows' fixed version is padded to four components, while the
authored string is preserved (for example, `1.0` is not rewritten as `1.0.0.0`).
Text fields are bounded to 1024 UTF-16 code units and reject NUL, control
characters, and malformed Unicode. Icons are limited to 16 MiB, 1–256 images,
and valid supported image data with dimensions in 1–256 pixels.

Application resources and `app-info.dict` describe the application. `version`
and `package require machteld` still describe the unchanged runtime API.
Machteld-specific resource fields identify the runtime, and its existing
`build-info.dict` is copied unchanged when available. These descriptive records
do not authenticate the publisher. There is no automatic signing: any signing
must happen separately, after packaging has finished, and hashes must then be
computed from the signed bytes.

## External DLLs

The supported example keeps DLLs on disk beside the executable and loads their
explicit disk paths; `wrap` does not arrange loading native code from its ZIP.
Keep a separately reviewed adjacent-file inventory, including dependency DLLs
and their license notices. Load an explicitly selected absolute disk path based
on `[file dirname [info nameofexecutable]]`, never the current working directory.
Use a fresh complete deployment folder so a failed build cannot mix a new
executable with old libraries. Replacing a multi-file deployment is a separate
operation: `wrap`'s atomic guarantee covers its executable, not the whole folder.

The source example in `examples/external-extension` demonstrates a tiny Tcl-stubs
extension and an explicit adjacent-file deployment. Its build compiler is for
the extension author; users need no compiler to wrap or run the resulting
application. The [external libraries guide](extensions.md) explains this manual
dependency policy. No dependency discovery, downloading, or resolver is added.
