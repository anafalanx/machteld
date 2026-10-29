---
type: architecture
title: Architecture
description: How the executable, native palette, prelude, entry gate, and wrappers fit.
tags: [machteld, architecture, tcl, windows]
---

# Architecture

The product has three layers:

1. **Native core.** C commands wrap Win32 Job Objects and process creation,
   ConPTY, directory and reparse-point traversal, ReadDirectoryChangesW,
   WinHTTP, BCrypt, JSON, and statically linked SQLite.
2. **Tcl runtime.** The prelude adds `version`, `manifest`, `scope`,
   `pty expect/strip`, `cli`, `log`, `worker`, `pool`, `pmap`, `docs`, `help`,
   and `wrap`, then provides package `machteld 0.22`.
3. **Program.** An opted-in entry remains ordinary Tcl. It receives normal
   `argv` and resolves palette commands through `::machteld` on the global
   namespace path.

Startup registers the native commands, loads the embedded prelude, and applies
the entry gate before Tcl evaluates a program. The gate parses the first command
without evaluating it. Interactive startup is still available when no file is
selected; `--help`, `--version`, `--docs`, and the subordinate `wrap` route are
handled by the host.

For a native startup file, the host captures the file once, checks that decoded
value, and evaluates the same value; a second path read cannot substitute a
different entry after validation. Subsequent `source`, `load`, file access, and
subprocess operations are ordinary trusted Tcl behavior. The gate is a
dependency declaration, not code review, permission reduction, or a sandbox.

## Hosts and archives

The distribution executable contains Tcl/Tk libraries, docs, the prelude, and
console and GUI basekits. The console host enters `Tcl_Main`; the GUI host enters
`Tk_Main` without creating a console. The console host initializes Tk only after
`package require Tk`; the GUI host initializes Tk at startup because it is a
windowed host.

`wrap` copies one basekit, the complete Machteld prelude, Tcl/Tk libraries, and
the program into an appended zipfs. Both basekits link the same native core and
SQLite, so a wrapped entry sees the same programmatic Machteld 0.22
machine-control API. Runtime libraries and license notices are always included.
The complete versioned reference corpus is verified and copied only when
`--with-docs` is requested; it is omitted by default. Application assets are
unaffected. Nested wrapping basekits remain distribution-only and are not copied
recursively.

Tcl 9.0.4 predates the upstream fix for ACL-restricted Windows path
normalization. Dependency bootstrap applies Tcl core check-in `0ac314cb96`
verbatim to `win/tclWinFile.c`, after verifying the archive input, patch, and
patched-output hashes. This prevents standalone zipfs startup from losing an
executable path component when an ancestor can be traversed but not enumerated.

## Self-description

Incremental development builds carry an inert `build-info.dict` at the archive
root, beside `machteld.tcl`. It records schema `1`, channel `development`, the
runtime API version, the working tree's base source revision, an input
SHA-256, and the reference corpus SHA-256. The revision is not a clean-checkout
claim: the input digest identifies the actual build ingredients, including
uncommitted runtime changes. The record contains no build-machine paths or
wall-clock timestamps. It is embedded when the build publishes its local
executable and copied into wrapped tools even when their reference is omitted.
It describes the embedded runtime, not the wrapped application's authorship or
version.
Clean reconstruction and historical release artifacts do not carry this
development record. Absence is not evidence of signing or release authenticity;
verify the artifact's hash
and signature separately. `version` continues to report the runtime API version.

Wrapped applications additionally carry an inert `app-info.dict`. It describes
the selected application files and their hashes, host kind, reference choice,
and explicit application metadata, separately from the runtime identity.
`wrap --plan` returns that record before packaging. Optional Windows resources
are stamped on a disposable bare-host copy before the ZIP payload is attached;
the completed payload is checked before atomic publication. Neither this record
nor VERSIONINFO is a signature or an authority boundary.

Native metadata is an explicit table checked against the C registrations while
building. Tcl commands register explicit facts with `MetaDefine`. `manifest`
merges the two tables; an incompatible duplicate fails loudly. The sole
intentional cross-layer extension is `pty`: Tcl adds `expect` and `strip` to the
native ensemble.

No command body, helper name, option-looking comment, or trailing function is
scanned to infer public behavior. Refactoring implementation text cannot change
the advertised API.

The documentation build transforms pinned upstream Tcl/Tk manpages into
normalized Markdown while preserving source and HTML representations. It
combines those pages with authored Machteld command references, creates a
deterministic catalog/search index, and hashes the corpus. `docs` reads only
the executable's self-mounted payload and exposes exact lookup, sections, bounded
search, verification, provenance, and safe extraction. The distribution always
carries this corpus; wrapped applications opt in with `--with-docs`. Without
it, `docs schema` still describes the API, corpus queries report `DOCS
unsupported`, and bare `help` explains how to obtain the reference.
The payload is trusted because the executable was chosen as trusted code;
corpus hashes do not independently authenticate an unsigned executable. During
unreleased work the runtime version alone does not identify the source revision
or corpus: compare the embedded build and reference identities as well.

The development loop records its stages by content: compiled objects, the
prelude, each reference generation, and the final package. A reference
generation is immutable and is reused while the documentation, the generator,
and the runtime version stay the same; an authored page edit generates the
reference again, and a Tcl implementation edit does not invalidate
documentation. Runtime version declarations must still agree, and a version
change invalidates the reference record. Corrupted or incomplete records are
misses, not freshness evidence. The generator's serializers are build-only Tcl,
not runtime features, and release builds do not reuse development records.

`tools/gate.tcl` builds and then runs every test group; `--group` selects
groups to run against an existing executable without building. `fast` needs no
compiler; `integration` adds native fixtures, native stream limits, and
build-cache tests; `packaging` checks entry points, wrapping, publication, and
Windows metadata. A run that tests an executable identifies it by version and
SHA-256 and refuses one that changes during the run. `native-validation` adds
headless lifetime stress and the undefined-behavior-trapped native drivers;
worker-scaling measurements (`--native-scaling`) and static analysis with
capability-probed instrumentation (`--native-analysis`) are explicit options.
Negative controls must fail as expected; unavailable sanitizer runtimes are
reported, never counted as passing instrumentation. See
[native validation](native-validation.md) for coverage and limitations.
`reference-generator` is the separate, expensive determinism group: two cold
conversions compared byte for byte. `tools/dev.tcl test` likewise tests
without an implicit build. The GUI model runs in `fast`; `--interactive-gui`
explicitly enables the visible Tk-widget checks. Manual interaction remains
part of release acceptance.

## Lifetime

The host owns, but does not join, a root Job Object configured to kill its
members when the host closes its last handle. `child`, `run`, pool workers, and
PTYs are born into both that root job and a narrower per-command job. `scope`
gives a lexical lifetime inside the process. `detach` is the explicit exception:
on success it belongs to no Windows job and creates an independent process tree.
An enclosing Windows job may forbid breakaway, in which case launch is rejected.

These are ownership and resource-management boundaries, not security isolation.
`-dir` does not restrict paths, `-env` overlays inherited variables rather than
removing credentials, and a child normally runs as the launching user. Native
DLLs execute inside the host with that same authority. The host exposes ordinary
Tcl facilities as well as the palette.

The native wrappers are not uniformly asynchronous. HTTP, directory walks,
hashing, storage and packaging can block; a timeout may cover one operation or
network phase rather than a total wall-clock budget. `pool`'s evented channels
and application-owned children let a Tk controller keep slow work outside the
GUI thread. See [execution model](execution-model.md) before composing callbacks.
