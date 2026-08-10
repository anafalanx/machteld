---
type: plan
title: machteld as the front door
description: Retire the tool factory; become the environment director that z.exe is today, in Tcl/Tk and C.
tags: [machteld, front-door, z, plan]
timestamp: 2026-08-10
---

# machteld as the front door

`z.exe` is 10,613 lines of Go (plus 5,666 of tests, 98 files, **no external dependencies**) and it
is the single entrance to `C:\dev`. This plan replaces it with machteld, in the same form every
other application here is built in: statically linked Tcl/Tk 9.0.4 inside a C host, one exe. The project keeps the name **machteld**; the artefact becomes **`mt.exe`**,
which is what lands at `C:\dev\mt.exe` beside (and eventually instead of) `z.exe`.

## Why this is a smaller ask than it sounds

What z imports says what z *is*: `os` (79), `path/filepath` (72), `syscall` (16), `os/exec` (14),
`crypto/sha256` (5), `crypto/rand` (1). And what it does **not** import: no `net/http`, no
`archive/zip`, no `archive/tar`, no `compress/*`. z downloads nothing and unpacks nothing.

That profile is this toolkit's home ground rather than Go's:

| z leans on | machteld already has |
|---|---|
| `os` + `path/filepath` — the bulk | Tcl's `file`, `glob`, `string`; denser than Go for this |
| `os/exec` | `run` / `child` — *better* here: born-in-job, tree-kill, die-with-parent, caps |
| `crypto/sha256`, `crypto/rand` | `hash`, over CNG, nothing vendored |
| `syscall` — reparse points, SIDs, 9 × `NewLazyDLL` | C, where these are one call instead of three |
| `encoding/json` for `manifest.json` | `json` |

The Win32-specific parts are the ones Go makes *hardest* and C makes easiest. And the front door's
core job — resolve a name to an executable, arguments, environment and working directory, then
spawn it under a controlled environment — is exactly what this palette was built for.

## What machteld stops being

**The tool factory is retired.** `wrap` exists to stamp standalone exes, and to do it machteld
carries *both* bare hosts inside itself: `machteld-bare.exe` (4.5 MB) and `machteld-bare-gui.exe`
(4.5 MB) inside a 10.2 MB exe. A front door does not stamp exes, so that weight goes and the
front door lands near 5 MB.

The five stamped tools (`changes`, `tasks`, `sums`, `life`, `lifelab`) become **helper scripts the
front door runs**, which is what they should have been: a front door that hosts Tcl/Tk already
gives them a window and the whole palette without a second artefact each.

## What it becomes instead

`els` refuses to run as a Tcl-script host on purpose — it is an application. machteld must do the
opposite: **be a script host**, because projects need helper scripts (`tools/tasks.tcl` and the
like) and a workspace director is where they belong.

The dispatch rule, in the prelude rather than the C, because `Tcl_Main` calls `AppInit` before it
looks at `argv`:

- `machteld` with no arguments → the shell, as `z` does today.
- first argument is an **existing file** → run it as a Tcl script (helper scripts, the suite).
- first argument starts with `-` → left alone; Tcl_Main's own options, and `-` is stdin.
- first argument is a **bare word** → a front-door name, resolved and spawned.

Nothing else changes behaviour, so every existing invocation keeps working while the front door
grows underneath it.

## Resolution, kept identical to z's

Builtin → curated tool → project or z script, with a collision qualified as `z:check` or
`project:check`. **No system-`PATH` fallback** — that is the property that makes the workspace
portable, and it is not negotiable. Every spawn receives `Z_ROOT` and `Z_HOME`, plus
`Z_PROJECT_ROOT` and `Z_PROJECT_NAME` when a project is active.

Tools and runtimes are read from `.z/manifest.json`, the file z already maintains: paths are
`Z_HOME`-relative, with per-tool `exeFromRoot` / `preFromRoot` / `envFromRoot` overrides. machteld
reads the same manifest rather than inventing a second inventory — the two must not disagree while
both exist.

## The steps

Each ends in something that builds, passes, and is worth committing.

1. **Resolution and inspection.** `front which`, `front env` (dict, `-json` for the wire form),
   roots discovery, manifest reading, project detection. Read-only: nothing is spawned, so it can
   be checked against the live `z` for agreement before anything depends on it.
2. **Spawning.** `front run`, and the argv dispatcher above. At this point
   `machteld rg -n TODO .` works and the environment it hands over is machteld's, not Go's.
3. **Retire the factory.** Drop `wrap`, the two embedded bares and the packaging step; the five
   tools become scripts. The exe halves.
4. **Strangle z, command by command.** 20 commands, mostly independent. The read-only ones first
   (`which`, `env`, `projects`, `status`, `tools`, `runtimes`), leaving `mirror`, `ledger` and the
   shell shim — the three biggest — until the pattern is proven.

## Where this stands (end of 2026-08-10)

Step 1 is in and measured against the live workspace:

- Roots discovery, project detection, manifest reading, resolution, `front roots|which|env|tools`.
- **226 of 273 curated tools resolve to an executable that is really on disk.** Zero resolve to a
  path that does not exist — the failures are all refusals, not wrong answers.
- The 47 that refuse do so by naming the manifest key they need:
  `preFromRoot` 13, `pre` 12, `envFromRoot` 21, `arg0` 1. That list *is* the remaining work for
  step 1, and it is small.
- Spot checks agree with the workspace's own layout: `rg` → `.z/t/rg/rg.exe`,
  `gcc` → `.z/r/msys2/ucrt64/bin/gcc.exe`.

**Next, in order:** finish those four keys; then diff every resolution against `z env --json`
for all 273 and make the agreement a gate; then step 2 (spawning and the argv dispatcher).

## The risk, named

**z.exe is the front door.** Rewriting what you use to enter the workspace, while using it daily,
is the most dangerous shape a project can have. Two things make it survivable: the commands are
independent, so this strangles rather than switches; and z already ships `verify`, `ledger`,
`mirror-restore` and `mirror-rehearsal` — the machinery for recovering this environment already
exists and is exercised.

Until step 4 finishes, `z.exe` stays exactly where it is and keeps working. machteld earns each
command by agreeing with z on it first.
