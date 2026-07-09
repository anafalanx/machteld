---
type: overview
title: What machteld is
description: A single-exe Windows 11 Tcl/Tk toolkit — a tool factory plus a machine-control primitive library.
tags: [machteld, overview, tcl, windows]
timestamp: 2026-07-09
---

# What machteld is

A single signed Windows executable (Win 11 23H2+) that is two things at once, sharing one statically-linked Tcl/Tk 9 runtime:

1. **A tool factory.** [`wrap`](/palette.md) turns a pure-Tcl/Tk program into its own standalone, signable exe — console or GUI — with **no compiler** and nothing to install on the target. Both subsystem basekits and the Tcl/Tk script libraries ride inside `machteld.exe`; it extracts the right one and appends your tool via zipfs — the els/starpack overlay. See [architecture](/architecture.md) and [packaging](/packaging.md).

2. **A machine-control primitive library**, bundled into every tool it builds and into its own REPL: kernel-grade process supervision (born-in-job launch, whole-tree kill, die-with-parent, resource caps, timeouts, capture, per-line streaming), interactive **ConPTY** steering (`pty` / `expect`), and a statically-linked **SQLite** (`store`). All in C, in-process, no DLLs.

You write **Tcl**; the power and the packaging are in **C**, exposed as a command palette. *Reach the metal, and ship the tool; don't invent a language.*

It is **drang in spirit** — the same crown-jewel process supervision — without a bespoke language, because Tcl was built for exactly this role: the **Tool Command Language**, an embeddable command surface extended in C. Its long-awaited consumer has arrived: the machine (see [the bet](/rationale.md)).

## Audience & posture

- **For its author first, product-shaped, audience later.** The first users are the small Tcl/Tk tools it builds (an editor; a live change-viewer) and its own machine-control REPL — not build/CI tooling for other projects.
- **Agents are the primary consumers — as a *quality bar*, not an AI feature.** Enforced by [the creed](/creed.md): a wrapped tool a model can drive safely and read at a glance.
- **Dogfood surface:** building and packaging small personal tools, and supervising / steering processes on your own box.
