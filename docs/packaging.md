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
```

That is the whole of it: the libraries the interpreter needs, the prelude, and the exe's own
documentation. The prelude is deliberately **not** named `main.tcl`, because `TclZipfs_AppHook`
auto-runs an archive-root `main.tcl` and this exe must reach [its dispatcher](front-door.md)
instead.

## No applications ride inside it

Two arrangements for shipping programs lived here and both are gone, five days and one day
respectively. What replaced them is nothing: **`mt.exe` resolves names and supervises what it
starts, and the programs live wherever their authors keep them** — run with `mt tcl app.tcl`, or
curated into the workspace like any of the other 273 tools.

The reasoning is one line: a front door that also hosts the applications is two things at once, and
the second one grows without limit. Every program added would have been another 5.9 MB artefact
(under `wrap`) or another name in the resolution order competing with the workspace's own (under
the zipfs arrangement), and neither cost has an end.

## What was here before: `wrap`, and then the zipfs tools

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

The GUI host went with it. Nothing double-clickable is produced here any more for a GUI subsystem
to serve, and a script that opens a window works from a console host — the window opens, the
terminal stays. When `mt --gui` lands it will make that choice once, at startup.

**Then the tools themselves went, the next day.** For one day the five rode in the archive at
`//zipfs:/app/tool/<name>/main.tcl`, with a resolution tier above the curated tools so `mt sums .`
found them. That was cheaper than `wrap` in every measurable way and it did not survive contact
with the question `wrap`'s retirement had actually raised: not *how* should this exe carry
applications, but *should it*. It should not.

Two things were learned building it that outlived it, and both are why
[`tcl`](palette.md) works the way it does: `Tcl_Main` reads its startup script into a local
**before** it calls `AppInit`, so a dispatcher cannot hand a script back to it; and a Tk program
that never calls `vwait` relies on `Tcl_Main` running `Tk_MainLoop` *after* the script returns, so
anything sourcing such a program must run that loop itself.

## Signing

`zipfs lmkimg` appends **after** the PE image, so a baked-in icon or manifest survives, and the
appended payload is inside the Authenticode hash. Sign last: **append-then-sign**, so the archive —
prelude, docs and tools — is covered by the signature.
