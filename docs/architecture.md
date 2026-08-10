---
type: architecture
title: Architecture
description: The single-exe starpack — a C host with statically-linked Tcl/Tk 9, an appended zipfs, and two subsystem bares.
tags: [machteld, architecture, starpack, tcl]
timestamp: 2026-07-09
---

# Architecture

A **starpack**: a C host + statically-linked **Tcl/Tk 9** + an appended **zipfs**. One signed exe, no install. Carved from the proven **sturm / els** host and its `.toolchain` (UCRT64 gcc, static `tcl9s` libs); SQLite is statically compiled in via the sturm bridge, so [`store`](palette.md) needs no DLL.

## Two hosts, one shared core

The C is split so the *same* object files serve two entry points:

- **`machteld_appinit.c`** — `Machteld_RegisterLibs`: registers the native libraries (`store`, the `run` / `child` / `pty` process substrate) and sources the Tcl prelude. **Shared.**
- **`machteld_main.c`** — the **console** host: `wmain` → `Tcl_Main`, Tk on demand. This is machteld itself — a branded `tclsh` with the palette preloaded (run a script, or a REPL).
- **`machteld_gui_main.c`** — the **GUI** host: `WinMain` (`-mwindows`) → `Tk_Main`, Tk up front, no console window. For windowed tools.

Linking those against the shared core yields two **bares**: `machteld-bare.exe` (console) and `machteld-bare-gui.exe` (GUI). A native library added to `Machteld_RegisterLibs` lands in **both** automatically — the two bares differ only in entry point and PE subsystem. (Why a compiled GUI host and not a subsystem byte-flip: see [packaging](packaging.md).)

## The exe

`machteld.exe` is the console host with an appended zipfs carrying the Tcl/Tk script libraries, the prelude (`machteld.tcl`), the docs bundle, and **both bare hosts** (`basekit/console.exe`, `basekit/gui.exe`, compressed) so that [`wrap`](packaging.md) can stamp a standalone tool exe with no toolchain. The five tools that used to ride along as well were removed on 2026-08-10; the hosts stayed, at a measured 130 ms of startup. See [packaging](packaging.md).

`TclZipfs_AppHook` self-mounts the appended zip at startup. The prelude is named `machteld.tcl`, not `main.tcl`, so it is *not* auto-run — machteld reaches its [dispatcher](front-door.md), which resolves the first argument as a NAME -- a script is named with the `tcl` verb (`mt tcl app.tcl`) -- and with no arguments drops to its REPL. 
