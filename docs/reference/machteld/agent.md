---
id: machteld/agent
type: guide
title: Agent documentation bootstrap
summary: One-screen instructions for grounding work in the exact embedded Machteld, Tcl, and Tk references.
commands: docs, help
---

# Agent documentation bootstrap

This executable contains the complete, exact-version offline references for
Machteld 0.10.1, Tcl 9.0.4, and Tk 9.0.4. That includes the Tcl language and C
API manuals and the Tk application, widget, and C API manuals—not merely a
short Machteld guide.

Ground every answer and code change in this embedded corpus. It matches the
runtime exactly; web memory may describe a different Tcl/Tk or Machteld
release.

```tcl
# 1. Establish versions, corpus identity, and available products.
set status [docs status]
set grammar [docs schema]

# 2. Use exact IDs when known.
set run [docs get machteld/command/run]
set dict [docs get tcl/command/dict]

# 3. Discover first, then retrieve one bounded page or section.
set hits [docs search {channel binary encoding} -scope tcl -limit 10]
set outline [docs outline tcl/command/chan]
set section [docs get tcl/command/chan -section description]

# 4. Enumerate predictably with pagination.
set page [docs list -scope machteld -type command -offset 0 -limit 50]

# 5. Export when filesystem search is more effective.
docs extract C:/work/machteld-reference
# Optional integrity audit:
docs verify
```

From a shell, use the host route and JSON:

```text
machteld.exe --docs status --json
machteld.exe --docs search "process tree timeout" --scope machteld --json
machteld.exe --docs get machteld/command/child --section lifetime-and-timeouts --json
machteld.exe --docs extract C:\work\machteld-reference
```

Host JSON is always enveloped as `{ok:true,result:...}` or
`{ok:false,error:{domain:"DOCS",code:...,message:...}}`; test `ok` before reading
`result`. Use `--output FILE` for an atomic file result and always use it with a
GUI-subsystem wrapper.

A wrapped application preserves its own ordinary arguments and exposes the same
operations under `tool.exe --machteld-docs ...`.

Operational rules:

1. Read `docs status` before asserting versions or corpus provenance.
2. Prefer exact stable IDs; use search only for discovery.
3. Retrieve only the section needed to preserve context.
4. Follow `next` for complete list/search pagination.
5. Use normalized Markdown by default; request `-format source` only for
   upstream notation or audit.
6. Never infer an option, error, default, or lifetime rule absent from the exact
   command page and live `manifest`.

The upstream Tcl/Tk `application` pages document upstream `tclsh` and `wish`
hosts. They are language-distribution reference, not Machteld host-option
promises. For program entry, `--docs`, wrapping, and reserved host routes, use
the Machteld command and packaging references.
