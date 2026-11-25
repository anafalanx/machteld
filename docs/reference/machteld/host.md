---
id: machteld/application/host
type: application
title: Running and packaging Tcl applications
summary: Run an opted-in Tcl script, start an application archive or build a verified archive for the shared runtime.
commands: machteld.exe, machteld pack, machteld --help, machteld --version, machteld --docs
---

# Running and packaging Tcl applications

## Host commands

```text
machteld.exe --help
machteld.exe --version
machteld.exe --docs status --json
machteld.exe program.tcl argument ...
machteld.exe program.machteld argument ...
machteld.exe pack source -o program.machteld
```

The program receives the arguments after its name in Tcl's `argv` list. An attached interactive terminal can start a prompt by running the host with no program. For batch work, pass a UTF-8 program file. The first command is a literal `package require machteld`, optionally with a literal version requirement or `-exact`. The host rejects redirected program input, `-` and an explicit `-encoding` option. A direct application controls its own command-line options.

## Archive inputs and results

`pack` accepts a single program file, an application directory with `main.tcl`, or a project dictionary declaring `schema 1`, a relative `entry` and the exact list of `files` to include. Each archive includes a checked inventory of member sizes and SHA-256 hashes. The output is published after verification. Open an archive by passing its path to the same runtime. Its mounted files are read-only. `app launch` produces a Tcl list that relaunches the same loaded generation.

```tcl
schema 1 entry ui/start.tcl files {ui/start.tcl ui/views.tcl assets/title.txt}
```

A renamed copy such as `notes.exe` runs an opted-in `notes.tcl` next to it when present. The executable selects the sibling independently of the current directory and passes its arguments to that script. A renamed host without a companion retains the usual host command line. `--docs` selects the reserved documentation route on the standard host. The convenience `docs` and `pack` words select a real same-named program file first.

## Errors and lifetime

Entry validation happens before evaluation. A missing or inconsistent archive inventory raises `MACHTELD ENTRY inventory`. File, encoding, entry declaration and version failures prevent startup. An archive remains pinned while one of its processes holds the generation. An ordinary new launch can open an updated archive while the old application finishes. The application owns the source files, per-user data paths and update policy. An inventory detects content changes and provides no publisher authentication.

Use `machteld/guide/packaging` for project and inventory limits, `machteld/command/app` for relaunch semantics, and `machteld/command/docs` for host JSON and extraction.
