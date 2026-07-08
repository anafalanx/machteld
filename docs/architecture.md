---
type: architecture
title: Architecture
description: The single-exe starpack — a C host with statically-linked Tcl/Tk 9 and an appended zipfs.
tags: [machteld, architecture, starpack, tcl]
timestamp: 2026-07-07
---

# Architecture

A **starpack**: a C host (`Tcl_Main`, console-subsystem; Tk statically present but initialized on demand; UTF-8 manifest; forward-slash `argv[0]`) + statically-linked **Tcl/Tk 9** + an appended **zipfs** carrying the Tcl palette prelude and resources. One signed exe, no install.

It is **carved from the proven sturm/els host** and its `.toolchain` (UCRT64 gcc, static `tcl9s` libs), plus the els sign-and-reprobe pipeline. SQLite is statically compiled in via the sturm bridge pattern, so [`store`](/palette.md) is available with no DLL.

The exe has two personalities selected at launch (same runtime, so this is trivial): a **script runner** (`machteld script.tcl`, plus a plain-terminal REPL) and later a **chrome console** (`machteld console`, popping the Tk cockpit — a `FreeConsole()` after Tk starts kills the stray console window). See the [roadmap](/roadmap.md) for the M0 carve and M4 console.
