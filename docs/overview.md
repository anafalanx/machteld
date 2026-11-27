---
type: overview
title: Overview
description: What Machteld is, what it runs, and what it deliberately is not.
tags: [machteld, windows, tcl, runtime]
---

# Overview

The development baseline, machteld 30, is a compact Windows runtime for Tcl/Tk 9
programs. It is strongest at what tools do: supervised processes and
terminals, files, HTTP, JSON, hashing and SQLite, in one executable that
installs nothing. It combines Tcl/Tk 9.0.4 with native supervision, ConPTY,
filesystem observation, WinHTTP, cryptography, JSON, and SQLite. The surface
stays Tcl-like: commands return values, options are explicit, and failures have
trap-able codes.

It is Vincent Vercauteren's own runtime, and it serves tools first. Use by
others is welcome, but adoption, a plugin marketplace, and integration with
another agent platform are not current product goals. The next public
release is 0.50. It integrates the Tcl-written application compiler with the
shared runtime so a project can introduce typed modules one file at a time.
The API-30 artifacts and signed 0.21 release have separate identities.
Build identities, artifact hashes, and verification receipts distinguish
artifacts that share a version while the release gate is in progress.

It is not an environment-specific resolver, package manager, command catalogue,
activity recorder, or replacement shell. It does not guess that an arbitrary Tcl file wants Machteld.
The program declares that dependency as its first executable command:

```tcl
package require machteld 30-

set tree [dirs C:/work -depth 2 -prune {.git node_modules}]
puts "[dict get $tree dirs] directories"
```

Run it with `machteld.exe program.tcl ?argument ...?`. The `.tcl` extension is a
convention, not a gate. The runtime parses that first command before evaluation,
loads the same Machteld package in every host, then lets Tcl handle the file and
its `argv` normally. The full host also runs a `.machteld` ZIP containing an
opted-in entry, its assets and an integrity inventory. [Packaging guide](packaging.md)

The palette has four layers:

1. `run`, `child`, `wait`, `scope`, `detach`, and `pty` control processes.
2. `watch`, `mtps`, `dirs`, `links`, `canon`, and `http` expose Windows facts.
3. `store`, `json`, `hash`, `cli`, and `log` support real programs.
4. `worker`, `pool`, `pmap`, `manifest`, `docs`, and `help` compose,
   explain, and ship them.

The shared executable packages an opted-in entry and selected assets with
`pack`. The same executable runs the archive, supplies its packages and
provides the offline reference. For standalone delivery, `wrap` builds an
executable with the app's own Windows name, version and icon. [Packaging](packaging.md)

The default model is linear and explicitly owned: operations use visible
deadlines where their command offers one, supervised children and PTYs
are born into the host-owned kill-on-close root and a per-command Job Object,
and `scope` shortens lifetime further. Channel events are used when a pool or GUI
genuinely needs concurrency.

This is trusted-code execution, not a sandbox. A script or loaded native
extension has the user's authority; the entry declaration does not restrict it.
Job Objects govern owned process lifetimes and requested resource limits, not
filesystem or credential access. `-dir` chooses a working directory and `-env`
overlays the inherited environment; neither creates isolation.

Long synchronous filesystem, HTTP, hashing, storage, and packaging calls can
block the caller. Keep them off a responsive Tk callback, using an owned worker
when necessary. The [execution model](execution-model.md) explains the evented
pattern; the [contract](contract.md) distinguishes intended Windows targets from
the acceptance evidence actually recorded.
