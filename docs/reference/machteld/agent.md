---
id: machteld/agent
type: guide
title: Agent documentation bootstrap
summary: One-screen instructions for grounding work in the exact embedded Machteld, Tcl, and Tk references.
commands: docs, help
---

# Agent documentation bootstrap

The Machteld distribution contains the complete, exact-version offline
references for Machteld 22, Tcl 9.0.4, and Tk 9.0.4. That includes the Tcl
language and C API manuals and the Tk application, widget, and C API manuals—not
merely a short Machteld guide. Wrapped tools include this corpus only when
created with `--with-docs`.

Use the matching embedded corpus to ground Machteld API claims and code changes;
recalled or online documentation may describe a different release. While 22
is in preparation, different artifacts can report the same runtime version.
Check the corpus/build identity and live `manifest`, not version alone.
Design guides and historical notes are context, not additional command options.

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
`result`. Use `--output FILE` for an atomic file result. GUI-subsystem wrappers
require that output path except for extraction, which already names its
destination.

A wrapped application preserves its own ordinary arguments and exposes the same
operations under `tool.exe --machteld-docs ...`. Without `--with-docs`, corpus
queries return `DOCS unsupported`; `docs schema` and `manifest` remain available,
and bare `help` explains the omission. Query the full same-version Machteld
executable for references, or rebuild the tool with `wrap --with-docs`. The
reserved host route and its JSON error envelope remain available even when the
corpus is absent; the same GUI output rules apply.

Operational rules:

1. Read `docs status` before asserting versions or corpus provenance.
2. Prefer exact stable IDs; use search only for discovery.
3. Retrieve only the section needed to preserve context.
4. Follow `next` for complete list/search pagination.
5. Use normalized Markdown by default; request `-format source` only for
   upstream notation or audit.
6. Never infer an option, error, default, or lifetime rule absent from the exact
   command page and live `manifest`.
7. Treat scripts, loaded extensions, and subprocesses as trusted code running
   with the user's permissions. Entry opt-in and Job Objects are not sandboxes;
   `-dir` is not confinement and `-env` is an inherited-environment overlay.
8. Keep blocking filesystem, HTTP, hashing, database, and packaging operations
   outside Tk callbacks that must remain responsive. Prefer the documented
   evented child/controller pattern for long work.

The upstream Tcl/Tk `application` pages document upstream `tclsh` and `wish`
hosts. They are language-distribution reference, not Machteld host-option
promises. For program entry, `--docs`, wrapping, and reserved host routes, use
the Machteld command and packaging references.

## When the palette is not enough

Machteld is a personal platform with a deliberately small palette. When a
concrete, authorized task needs more, an application may use ordinary Tcl,
explicitly deployed extensions, or an external program beside its executable.
This is a manual extension pattern, not a built-in resolver or a reason to
install software or broaden the user's task without asking. Apply two rules:

- **Contract-compliant.** The artifact plays by Machteld's published rules
  for its kind. A Tcl extension or script package enters through the
  extension mechanics and the precedence rule (`machteld/guide/extensions`).
  A DLL is fully trusted native code, not an isolated plugin.
  An external executable is launched, supervised, and killed through `run`,
  `child`, and `scope` like any process, and speaks structured output you
  define.
- **Explicitly deployed.** Apply the installation-free delivery policy:
  every dependency is verified as part of the target platform, included in the
  reviewed bundle with its notices, or omitted. This is an application-authoring
  rule, not a restriction enforced by `wrap`. Test the complete deployment;
  hashes and an inventory do not certify arbitrary dependencies or authenticate
  an unsigned application.

Order of consideration: the palette first; then ordinary Tcl; then an
artifact in the folder. Building beside the exe is not a workaround — it is
an explicit extension point. `examples/external-extension` demonstrates one
tested Tcl-stubs DLL; it does not establish support for unbundled database,
Office, or other native packages.
