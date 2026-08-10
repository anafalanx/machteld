---
type: concept
title: Packaging — one exe, and what rides inside it
description: How machteld is assembled, how its tools ride along, and why the tool factory was retired.
tags: [machteld, packaging, zipfs, starpack, tclkit, signing]
timestamp: 2026-08-10
---

# Packaging — one exe, and what rides inside it

`mt.exe` is a single file: a compiled host with a zip archive appended after its PE image, which
`TclZipfs_AppHook` mounts at startup. Everything the front door needs is in that archive.

```
//zipfs:/app/tcl_library/        the Tcl core script library
//zipfs:/app/tk_library/         the Tk core script library
//zipfs:/app/machteld.tcl        the prelude, with the derived manifest appended
//zipfs:/app/docs/               the docs bundle, which `help` serves
//zipfs:/app/tool/<name>/main.tcl  the tools it ships
```

The prelude is deliberately **not** named `main.tcl`: `TclZipfs_AppHook` auto-runs an archive-root
`main.tcl`, and this exe must reach [its dispatcher](front-door.md) instead. The tools are nested
one directory down for the same reason — `tools/package.tcl` fails the build if a tool ever lands
at the root.

## The tools ride along; they are not stamped

`mt sums .` sources `//zipfs:/app/tool/sums/main.tcl` **in this process**. No exe on disk, no
manifest entry, no process to start — the same argument that makes a builtin verb run in-process,
applied to a program instead of a command.

The front door replaces the two jobs `Tcl_Main` would have done for a script named on the command
line: it runs the event loop and it exits. Handing the script back to `Tcl_Main` would have been
neater and does not work — `Tcl_Main` reads its startup script into a local *before* it calls
`AppInit`, which is what sources the prelude, so by the time the front door knows that `sums` means
a script, the decision about what to evaluate has been taken.

## What was here before: `wrap`

Until 2026-08-10 this page described a **tool factory**. `wrap <tooldir> -o <out.exe>` copied the
Tcl/Tk libraries, the prelude and a tool's files into a staging tree and appended it onto a
**basekit** with `zipfs lmkimg` — the els/starpack overlay — producing a standalone exe that *was*
the tool, with no compiler in the loop. Two basekits rode inside `machteld.exe` for it, built from
the same objects against different entry points: a console `Tcl_Main` host and a GUI `WinMain`
(`-mwindows`) host, because the subsystem is compiled in rather than flipped — a console host in a
GUI subsystem has no valid standard channels and `puts stdout` throws *"can not find channel named
stdout"*.

It worked, and it was retired because **machteld stopped being a thing that makes exes**. The whole
mechanism cost 4.7 MB inside `machteld.exe` and produced five 5.9 MB artefacts to ship five files
of Tcl. Dropping it took the exe from **10.2 MB to 6.0 MB** and the build from six link steps to
one.

The GUI host went with it. There is no double-clickable tool exe left for a GUI subsystem to serve:
a tool is reached as `mt life`, typed into a shell that already has a console. Tk works from a
console host — the window opens and the terminal stays. When `mt --gui` lands it will make that
choice once, at startup, rather than once per tool.

## Signing

`zipfs lmkimg` appends **after** the PE image, so a baked-in icon or manifest survives, and the
appended payload is inside the Authenticode hash. Sign last: **append-then-sign**, so the archive —
prelude, docs and tools — is covered by the signature.
