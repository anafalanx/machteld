---
type: guide
title: Packaging
description: Creating and launching application archives on the shared Windows runtime.
tags: [machteld, pack, zipfs, deployment]
---

# Packaging

Machteld runs an opted-in UTF-8 script or an application archive. Programs share
the same executable, Tcl/Tk libraries, packages and offline reference.

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

## Application archive

```text
machteld.exe pack appdir -o myapp.machteld
machteld.exe myapp.machteld arg1 "arg two"
```

For a directory, put the opted-in entry at `appdir/main.tcl`. Put its scripts,
packages and assets alongside it. Pack a dedicated directory containing the
files you intend to deliver, and choose an output outside it. The ZIP root
contains `main.tcl` and the directory's contents, with no enclosing `appdir/`.
For a single script, `machteld.exe pack hello.tcl -o hello.machteld` stores
that script as the root `main.tcl`. The destination is replaced after the
completed archive has been checked. `pack` is a command-line action of the
full executable.

To select individual files, pass a UTF-8 project dictionary to the same
executable. Paths are relative to the dictionary's directory and the entry
must appear in the file list. The entry keeps its directory in the archive.

```tcl
schema 1 entry ui/start.tcl files {ui/start.tcl ui/messages.tcl assets/help.txt}
```

```text
machteld.exe pack app.dict -o app.machteld
machteld.exe app.machteld
```

The full host recognizes the `.machteld` suffix case-insensitively and mounts
the ZIP read-only for that process. The reserved root file
`machteld-inventory.dict` contains a UTF-8 Tcl dictionary with keys `schema`
(1), `entry` (the member path), and `files`. Each file record gives its byte
count in `bytes` and lowercase SHA-256 in `sha256`. The inventory describes
every application file and excludes itself. It accepts up to 10,000 files
and 4 MiB of inventory text. At startup the host checks the pinned archive's
members, sizes and hashes, then checks the entry's literal `package require
machteld` declaration. The hashes detect corruption. Anyone who can rewrite
the whole archive can also replace its inventory.

An archive from the unpublished 22 baseline has no embedded inventory.
Repack its original source directory using the current `pack` command.
The archive can use Tk and the host's installed packages. Changes to application data belong in a writable
native file.

For a desktop shortcut set the target to the runtime and pass the quoted
archive path as its first argument. The Windows console subsystem lets a
foreground terminal wait for exit and keeps redirected input and output
usable. The embedded detached console policy tells Explorer to launch the
same executable without allocating a console window.
[Windows console allocation policy](https://learn.microsoft.com/en-us/windows/console/console-allocation-policy)

In the entry, `$argv0` is the absolute native pathname of the archive,
`[info script]` names the mounted entry, and `$argv` contains the
arguments after the archive name. The working directory is the caller's.
Resolve assets relative to the entry. For example, an archive containing
`lib/myapp/pkgIndex.tcl` can add its own package directory explicitly.

```tcl
package require machteld 30-
set here [file dirname [info script]]
lappend auto_path [file join $here lib]
package require myapp
source [file join $here view.tcl]
```

Use `[list {*}[app launch] --worker]` to start a worker from the same application.
The worker receives `--worker` as an ordinary argument. For a `.machteld` archive,
the command selects the archive version that the parent opened. If version B
replaces version A at the distribution path, A can still start an A worker. A
fresh `machteld.exe myapp.machteld` opens B. `argv0` identifies the distribution
path in both generations. Use `info script` to locate assets belonging to the
running version. The same Tcl worker command also works for a loose script. [Application launch](reference/machteld/command/app.md)

## Distributing an application

A shortcut can point to `machteld.exe` and pass the quoted archive path.
Put a machine-local database under `[file join [app data local] MyApplication]`.
Use `app data roaming` for small settings meant to follow the user's profile.
Create the application's directory before saving. The signed file
identifies the runtime publisher. Give the application its own name, icon or
working directory in the shortcut as appropriate. On a supported Windows
desktop, the detached console policy permits Explorer to launch a Tk entry
without creating a console. A foreground terminal still waits for the process
and can redirect its standard streams. [Windows console allocation policy](https://learn.microsoft.com/en-us/windows/console/console-allocation-policy)

An existing executable built with signed 0.21 can still run independently. To
migrate, use its original sources and select the entry and assets in a project
dictionary. Run the resulting archive with the shared executable. A program
that needs to find an application-specific disk file can resolve it beside
the archive via `$argv0`. Use `[info script]` for files inside the archive
and `[info nameofexecutable]` for the runtime itself.

## External DLLs

Place an application-supplied DLL, its dependencies and notices in the
deployment folder. Keep its filename out of the archive file list, and load
it from a fully qualified native path. The source in `examples/external-extension`
builds a complete relocatable folder and records its file sizes and hashes.
Only the extension author needs a compiler. [External libraries](extensions.md)
