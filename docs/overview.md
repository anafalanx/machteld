---
type: overview
title: Overview
description: What Machteld is, what it runs, and what it deliberately is not.
tags: [machteld, windows, tcl, runtime]
---

# Overview

machteld 0.20 is a single-executable Windows runtime for small machine-control
programs. It combines Tcl/Tk 9.0.4 with native supervision, ConPTY, filesystem
observation, WinHTTP, cryptography, JSON, and SQLite. The surface stays Tcl-like:
commands return values, options are explicit, and failures have trap-able codes.

It is not an environment-specific resolver, package manager, command catalogue,
activity recorder, or replacement shell. It does not guess that an arbitrary Tcl file wants Machteld.
The program says so as its first executable command:

```tcl
package require machteld 0.20

set tree [dirs C:/work -depth 2 -prune {.git node_modules}]
puts "[dict get $tree dirs] directories"
```

Run it with `machteld.exe program.tcl ?argument ...?`. The `.tcl` extension is a
convention, not a gate. The runtime parses that first command before evaluation,
loads the same Machteld package in every host, then lets Tcl handle the file and
its `argv` normally.

The palette has four layers:

1. `run`, `child`, `wait`, `scope`, `detach`, and `pty` control processes.
2. `watch`, `mtps`, `dirs`, `links`, `canon`, and `http` expose Windows facts.
3. `store`, `json`, `hash`, `cli`, and `log` support real programs.
4. `worker`, `pool`, `pmap`, `wrap`, `manifest`, `docs`, and `help` compose,
   explain, and ship them.

`wrap` is subordinate to this runtime boundary. It accepts only an opted-in
Machteld entry and produces a console or GUI exe with the same machine-control
and data API and version, including static SQLite and the complete offline
Machteld/Tcl/Tk reference corpus. Nested wrapping remains in the distribution
host. It is a deployment form, not a second language.

The default model is linear and explicitly owned: long-running operations use
visible deadlines where their command offers one, supervised children and PTYs
are born into the host-owned kill-on-close root and a per-command Job Object,
and `scope` shortens lifetime further. Channel events are used when a pool or GUI
genuinely needs concurrency.
