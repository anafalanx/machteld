---
type: principles
title: The creed
description: The design tests applied to Machteld's public surface.
tags: [machteld, principles, design]
---

# The creed

1. **No AI inside.** Machteld provides deterministic hands; an agent may be an
   external user, never a runtime dependency.
2. **Machine-legible is human-legible.** Structured values, plain Tcl, and clear
   prose must describe the same behavior.
3. **Determinism over cleverness.** No project-specific resolver or command
   catalogue, locale-dependent protocol, or guessed unit. A bare executable
   name uses Machteld's deterministic `PATH`-only search.
4. **The palette describes itself.** `manifest` facts are explicitly authored,
   validated at build time, and returned as structured data at runtime. `docs`
   carries the complete exact-version Machteld/Tcl/Tk reference, with stable
   identifiers, bounded retrieval, search, hashes, and extraction for agents.
5. **Errors are contract.** Machteld-defined public failures carry
   `{MACHTELD DOMAIN code}`; Tcl language errors keep Tcl's own codes.
6. **Orthogonal and small.** Prefer one composable primitive over a policy stack.
   Version 0.x may still remove mistakes; 1.0 will freeze the surface.
7. **Vanilla Tcl, extended.** Add commands and packages; do not mutate Tcl syntax.
8. **One language boundary.** Tcl owns program control and Tk owns graphical
   interfaces. Native C/C++ facilities appear only as Tcl-shaped commands;
   external software is started, questioned, supervised, and stopped as an
   ordinary process.

The practical thesis is simple: design for the machine as the most exacting
reader, without putting a machine in the product.
