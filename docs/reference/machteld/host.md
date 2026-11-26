---
id: machteld/application/host
type: application
title: Running and packaging Tcl applications
summary: Run an opted-in Tcl script, start an application archive or build a verified archive for the shared runtime.
commands: machteld.exe, machteld pack, machteld --help, machteld --version, machteld --docs, machteld --check, machteld --manifest
---

# Running and packaging Tcl applications

## Host commands

```text
machteld.exe --help
machteld.exe --version
machteld.exe --docs status --json
machteld.exe --check program.machteld --json
machteld.exe --manifest command child wait --json
machteld.exe program.tcl argument ...
machteld.exe program.machteld argument ...
machteld.exe pack source -o program.machteld
```

The program receives the arguments after its name in Tcl's `argv` list. An attached interactive terminal can start a prompt by running the host with no program. For batch work, pass a UTF-8 program file. The first command is a literal `package require machteld`, optionally with a literal version requirement or `-exact`. The host rejects redirected program input, `-` and an explicit `-encoding` option. A direct application controls its own command-line options.

## Check an application without running it

`machteld.exe --check TARGET --json` accepts a UTF-8 script, a directory with
`main.tcl`, a project dictionary, or a `.machteld` archive. Relative paths
resolve from the caller's current directory. For directories and projects the
host computes the same selected-file inventory as `pack`. For archives it
verifies every member against the embedded sizes and hashes. It checks the
entry's literal declaration and version requirement against this executable,
then parses the entry's top-level Tcl command boundaries without evaluating it.
Braced procedure bodies and other scripts constructed or sourced at runtime
still require application tests.

On success the host writes one JSON object to stdout and exits 0. The
`result` contains `schema` (1), `kind`, absolute `path`, relative `entry`,
selected application file count `files`, `executed` (false) and `doc`. On
failure it writes `{"ok":false,"error":{...}}` to stderr and exits 1.
Diagnostics carry `domain`, stable `code`, `message`, and `doc`. A file
diagnostic includes its `path`, plus a one-based `line` when the parser can
locate the error. Archive member diagnostics use `archive.machteld!/entry.tcl`.
Omit `--json` for a Tcl dict on success and a plain message on failure.

## Archive inputs and results

`pack` accepts a single program file, an application directory with `main.tcl`, or a project dictionary declaring `schema 1`, a relative `entry` and the exact list of `files` to include. Each archive includes a checked inventory of member sizes and SHA-256 hashes. The output is published after verification. Open an archive by passing its path to the same runtime. Its mounted files are read-only. `app launch` produces a Tcl list that relaunches the same loaded generation.

```tcl
schema 1 entry ui/start.tcl files {ui/start.tcl ui/views.tcl assets/title.txt}
```

A renamed copy such as `notes.exe` runs an opted-in `notes.tcl` next to it when present. The executable selects the sibling independently of the current directory and passes its arguments to that script. A renamed host without a companion retains the usual host command line. `--docs` selects the reserved documentation route on the standard host. The convenience `docs` and `pack` words select a real same-named program file first.

## Errors and lifetime

Entry validation happens before evaluation. A missing or inconsistent archive inventory raises `MACHTELD ENTRY inventory`. File, encoding, entry declaration and version failures prevent startup. An archive remains pinned while one of its processes holds the generation. An ordinary new launch can open an updated archive while the old application finishes. The application owns the source files, per-user data paths and update policy. An inventory detects content changes and provides no publisher authentication.

Use `machteld/guide/packaging` for project and inventory limits, `machteld/command/app` for relaunch semantics, and `machteld/command/docs` for host JSON and extraction.
