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

## Step 1 is done: 273 of 273 agree

`test/front_agree.tcl` asks both front doors to resolve every curated tool and diffs the answers:
**273 / 273 agree, 0 differ, 0 refused, from the workspace root and from inside a project.** It
compares the executable, the environment overlay, the PATH the tool adds, and the prepended
arguments — not the inherited PATH tail, which is the caller's, nor the caller's own arguments,
which are not resolution.

That agreement was bought by reading the workspace's resolver instead of inferring from key names,
and **five of the rules are the opposite of what the names suggest**:

- `toolEnv` is called with **home**, not root — every relative path in a tool entry is
  `MT_HOME`-relative, including `envFromRoot`.
- The **`t/` directory scan wins over `exeFromRoot`**, and there `exe` is a *filename inside*
  `t/<name>/`, not a path.
- A tool whose executable is **not on disk does not resolve at all** — so a catalogued but
  uninstalled tool is a clean not-found rather than a phantom path.
- `path` entries are **filtered by existence** and deduped case-insensitively before being
  prepended.
- Only the **bracketed** token forms expand (`${Z_HOME}`, `$(Z_HOME)`, `%Z_HOME%`) — never the
  bare word, which the first version substituted and would have corrupted any argument merely
  containing those letters. And when expansion lands inside the workspace the **whole** path is
  normalised, which exactly one tool of 273 (`glow`) noticed.

A project is likewise **not** "a directory under the root": it is the nearest ancestor carrying a
project file, and its name drops a leading underscore (`_els` → `els`). The first version claimed
a project wherever it stood, and the diff caught it.

**`ps` is renamed `mtps`.** It was the only name in the workspace where a palette verb and a
curated tool collided, and the front door should hand `ps` to the MSYS2 tool the workspace
curates. Renaming removes the collision entirely rather than settling it with a precedence rule,
so there is now **no name that resolves two ways**. Its error domain moved with it, `PS` → `MTPS`
— caught by the registry gate, which failed the build until the contract was updated.

**Next:** step 2, spawning and the argv dispatcher.

## The risk, named

**z.exe is the front door.** Rewriting what you use to enter the workspace, while using it daily,
is the most dangerous shape a project can have. Two things make it survivable: the commands are
independent, so this strangles rather than switches; and z already ships `verify`, `ledger`,
`mirror-restore` and `mirror-rehearsal` — the machinery for recovering this environment already
exists and is exercised.

Until step 4 finishes, `z.exe` stays exactly where it is and keeps working. machteld earns each
command by agreeing with z on it first.
