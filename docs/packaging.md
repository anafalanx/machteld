---
type: concept
title: Packaging — one exe, and what rides inside it
description: How machteld is assembled, what rides inside it, and how `wrap` stamps a tool of your own.
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
//zipfs:/basekit/console.exe     a bare host, console subsystem   -- for `wrap`
//zipfs:/basekit/gui.exe         a bare host, GUI subsystem       -- for `wrap`
```

The prelude is deliberately **not** named `main.tcl`, because `TclZipfs_AppHook` auto-runs an
archive-root `main.tcl` and this exe must reach [its dispatcher](front-door.md) instead. The
packager fails the build if a root `main.tcl` ever lands here — and the dispatcher relies on that,
standing aside when it finds one, because a root `main.tcl` means it is running inside a stamped
tool rather than as a front door.

## `wrap` — a tool of your own

```tcl
wrap <tooldir> -o <out.exe> ?--gui|--console? ?--no-prelude?
```

`<tooldir>` holds the tool's Tcl, entry point `main.tcl` — auto-run by `TclZipfs_AppHook`, which is
what makes the result *be* the tool. `wrap` copies the Tcl/Tk script libraries, the
[prelude](palette.md) and the tool's files into a staging tree and appends it onto a **basekit**
with `zipfs lmkimg`: the els/starpack overlay, no compiler, no `sdx`, no Tcl install.

**Both basekits ride inside `mt.exe`** at `//zipfs:/basekit/{console,gui}.exe`, built from the same
objects against different entry points. So `mt.exe` alone can stamp — nothing else needed, on any
machine. A wrapped tool carries no basekits of its own, which is why only `mt.exe` can wrap.

The subsystem is *compiled in*, not a PE byte-flip: a console host run in a GUI subsystem has no
valid standard channels and `puts stdout` throws *"can not find channel named stdout"*. Two hosts,
the way tclkit has always done it (`tclkit` vs `tclkitsh`).

**It costs the front door about 13 ms per invocation**, on a same-session A/B of the two builds:
6.0 MB answers `mt version` in ~22 ms with a trivial prelude, 10.2 MB in ~22 ms too, and the whole
difference shows up in the mount. The first measurement published here said 130 ms and was wrong —
it compared two builds that differed in more than their basekits, and the real cost was hiding
somewhere else entirely. [The log](log.md) has the correction and what was actually slow.

## No applications ride inside it

`wrap` is a capability; the programs are not. Two arrangements for shipping *applications* lived
here — stamped exes built by the build itself, then scripts in the archive — and both are gone.
**`mt.exe` resolves names, supervises what it starts, and can hand you an exe. The programs live
wherever their authors keep them**, run with `mt tcl app.tcl` or curated into the workspace like
any of the other 273 tools.

A front door that also hosts the applications is two things at once, and the second grows without
limit: every program added is another name in the resolution order competing with the workspace's
own, permanently.

## What was here before: the five tools

Five programs — `changes`, `tasks`, `sums`, `life`, `lifelab` — were built with this and shipped
beside it, each `wrap`'d into its own 5.9 MB exe by the build itself. On 2026-08-10 `wrap` was
retired to save the 4.7 MB of embedded basekits, the five became scripts riding in the archive at
`//zipfs:/app/tool/<name>/main.tcl` for a few hours, and then all of it was undone in both
directions: the tools were deleted, and `wrap` came back when a real receiver for it turned up
(colleagues on a share, no Tcl, no install rights). [The register](direction.md) has all three
turns, because the reasoning at each step was locally sound and that is the interesting part.

What the five taught outlived them. `changes` and `tasks` named the C capabilities they needed,
which is where `watch` and `mtps` came from; `sums` proved this exe can spawn copies of itself as a
pool of persistent workers; `life`/`lifelab` were the stress experiment that found the
cap-enforcement and `child wait -timeout` defects. And two facts about `Tcl_Main`, found while
making them run in-process, are why
[`tcl`](palette.md) works the way it does: `Tcl_Main` reads its startup script into a local
**before** it calls `AppInit`, so a dispatcher cannot hand a script back to it; and a Tk program
that never calls `vwait` relies on `Tcl_Main` running `Tk_MainLoop` *after* the script returns, so
anything sourcing such a program must run that loop itself.

## Signing

`zipfs lmkimg` appends **after** the PE image, so a baked-in icon or manifest survives, and the
appended payload is inside the Authenticode hash. Sign last: **append-then-sign**, so the archive —
prelude, docs and basekits — is covered by the signature. A tool `wrap` stamps is likewise
unsigned when it comes out: append, then sign, so the tool's own code is inside the hash.
