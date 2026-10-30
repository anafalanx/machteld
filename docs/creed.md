---
type: principles
title: The creed
description: The design tests applied to Machteld's public surface.
tags: [machteld, principles, design]
---

# The creed

These are design rules for Vincent Vercauteren's personal platform, not a claim
that every current primitive is asynchronous, time-bounded, or a security
boundary. The command reference states implemented behavior; future design
intent does not add an API.

1. **No AI inside.** Machteld provides deterministic hands; an agent may be an
   external user, never a runtime dependency.
2. **Machine-legible is human-legible.** Structured values, plain Tcl, and clear
   prose must describe the same behavior.
3. **Determinism over cleverness.** No project-specific resolver or command
   catalogue, locale-dependent protocol, or guessed unit. A bare executable
   name uses Machteld's deterministic `PATH`-only search.
4. **The palette describes itself.** `manifest` facts are explicitly authored,
   validated at build time, and returned as structured data at runtime. The
   Machteld distribution carries the complete exact-version Machteld/Tcl/Tk
   reference through `docs`, with stable identifiers, bounded retrieval, search,
   hashes, and extraction for agents. Wrapped applications include that corpus
   only with `--with-docs`; their runtime metadata remains available without it.
5. **Errors are contract.** Machteld-defined public failures carry
   `{MACHTELD DOMAIN code}`; Tcl language errors keep Tcl's own codes.
6. **Orthogonal and small.** Prefer one composable primitive over a policy stack.
   A later runtime number may still change the surface when a concrete need
   justifies it; a program that must be read again first names an upper bound.
   A future compatibility freeze is a decision to make, not a scheduled release.
7. **Vanilla Tcl, extended.** Add commands and packages; do not mutate Tcl syntax.
8. **One language boundary.** Tcl owns program control and Tk owns graphical
   interfaces. Native C/C++ facilities appear only as Tcl-shaped commands;
   external software is started, questioned, supervised, and stopped as an
   ordinary process.
9. **Ownership is not isolation.** Explicit lifetimes, inventories, and limits
   make trusted programs easier to manage. They do not sandbox Tcl, loaded DLLs,
   or the user's subprocesses.

The practical thesis is simple: design for the machine as the most exacting
reader, without putting a machine in the product.
