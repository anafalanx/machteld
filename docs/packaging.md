---
type: concept
title: Packaging — the tool factory
description: How machteld turns a pure-Tcl/Tk program into a standalone, signable exe with no compiler.
tags: [machteld, packaging, wrap, starpack, tclkit, signing]
timestamp: 2026-07-09
---

# Packaging — the tool factory

machteld is a **personal tclkit**: one compiled runtime that stamps out standalone tool exes with **no compiler in the loop**.

## `wrap`

```tcl
wrap <tooldir> -o <out.exe> ?--gui|--console? ?--no-prelude?
```

`<tooldir>` holds the tool's Tcl — its entry is `main.tcl`, auto-run by `TclZipfs_AppHook` — plus any resources. `wrap` copies the Tcl/Tk script libraries, the [prelude](/palette.md) (unless `--no-prelude`), and the tool's files into a staging tree, then appends that tree onto a **basekit** via `zipfs lmkimg` (the els/starpack overlay). The result is a single exe that *is* the tool.

## Self-contained

Everything `wrap` needs rides **inside `machteld.exe`**: the Tcl/Tk libraries, the prelude, and **both** basekits — `basekit/console.exe` and `basekit/gui.exe` — compressed in its own zipfs. `wrap` extracts the right basekit for the chosen subsystem and appends onto it. No external toolchain, no `sdx`, no Tcl install. (A wrapped tool carries no basekits, so only `machteld.exe` can `wrap`.)

## Console vs GUI — two bares, one difference

The two basekits are built from the **same object files** — the whole [machine-control library](/palette.md) and the shared `Machteld_RegisterLibs` — linked against different entry points: a console `Tcl_Main` host and a GUI `WinMain` (`-mwindows`) host. So a GUI tool shows no console window, a console tool has real stdio, and **a C library added to the shared AppInit lands in both bares** with no duplication.

The subsystem is *compiled in*, not a PE byte-flip: a console host run in a GUI subsystem has no valid standard channels — `puts stdout` throws *"can not find channel named stdout"* — so the proper `WinMain` host is used, the way els / tclkit (`tclkit` vs `tclkitsh`) have always done it.

## Signing

`wrap` produces an **unsigned** exe; sign it last (**append-then-sign**). The appended tool payload is inside the Authenticode hash, so the tool's own code is covered by the signature — wrap onto an unsigned basekit and sign the result.
