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

> **They were removed from the project instead, on 2026-08-10.** This paragraph is the plan as
> written, and it was half right: the second artefact each should indeed go. What it did not ask is
> whether the *first* one belongs here either. A front door resolves names and supervises what it
> starts; the applications belong wherever their authors keep them, reached with `mt tcl app.tcl`
> or curated into the workspace like any other tool.

## What it becomes instead

`els` refuses to run as a Tcl-script host on purpose — it is an application. machteld must do the
opposite: **be a script host**, because projects need helper scripts (`tools/tasks.tcl` and the
like) and a workspace director is where they belong.

The dispatch rule, in the prelude rather than the C, because `Tcl_Main` calls `AppInit` before it
looks at `argv`. As planned:

- `machteld` with no arguments → the shell, as `z` does today.
- first argument is an **existing file** → run it as a Tcl script (helper scripts, the suite).
- first argument starts with `-` → left alone; Tcl_Main's own options, and `-` is stdin.
- first argument is a **bare word** → a front-door name, resolved and spawned.

> **What was actually built is shorter, and the middle line is why.** "Is an existing file" was
> refused in step 2 — it would let a stray file in the working directory change what `mt rg` means,
> which is a `PATH` fallback wearing different clothes — and replaced by a **shape** test: a
> separator or a `.tcl` extension means a script. Step 3 removed that too. **The first argument is
> a name. There is no test.** A script is named with the `tcl` verb: `mt tcl app.tcl`.

Every existing invocation kept working until step 3, which broke exactly one of them — `mt app.tcl`
— deliberately, once, at 71 call sites.

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
   tools become scripts. The exe halves. *(Done — and the second half of that sentence went
   further than planned: the tools were removed from the project, not turned into scripts the exe
   carries. See below.)*
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

**Step 2 is done too.** `front run ?-inherit?`, builtins in-process, and the argv dispatcher:
`mt rg --version` prints `ripgrep 15.1.0`, `mt version` answers `0.3.0` without spawning anything,
an unknown name exits 127, and a `.tcl` path still ran as a script -- that last part until step 3, see below.

The one thing only running it could have shown: by the time AppInit executes, `Tcl_Main` has
**already taken the first argument as the script name** — it is in `argv0`, with the rest in
`argv`. Reading `argv[0]` made the front door resolve the first *argument* of every command, so
`mt script.tcl a b` went looking for a tool called "a".
(That spelling is `mt tcl script.tcl a b` now; the point about `argv0` is unchanged.)

**The [journal](journal.md) is built and recording.** `front run` writes a row before the spawn and
closes it after, in `$MT_HOME/mt.db`; `front journal` opens it for a reader, `journal rows` queries
it. Everything the recorder does is inside a `catch`, so a journal that cannot be written is a
front door that still runs the tool.

Its cost was paid somewhere unrelated. A new C file compiled, linked and ran while `manifest` never
saw the verb, because the generator worked off two hand-kept lists and the runtime called anything
it had no entry for "Tcl". Both lists are now read out of the source, and the suite asks the running
binary whether every C verb was seen — which is the answer to the failure class this project keeps
meeting: **a derivation that quietly reports nothing when the code moves is worse than no
derivation, because it looks like an answer.**

Still not built, and named rather than assumed: the `pid` at insert and the `mtps` reconciliation
that would let `rows -live` tell a running process from one whose front door died, and the
once-per-session pruning — so today the file only grows.

## Step 3 is done: the factory is retired, 10.2 MB → 6.0 MB

`wrap`, both embedded bare hosts, the GUI `WinMain` host and the tool-stamping loop at the end of
the build are gone. The build used to finish by running the exe it had just produced five times, to
turn five tool directories into five 5.9 MB standalone exes; it now finishes when the exe is built.

**The tools then left the project entirely, the same day.** For a few hours they rode inside
`mt.exe` at `//zipfs:/app/tool/<name>/main.tcl`, with resolution gaining a third tier — builtin
verb → shipped tool → curated tool — so `mt sums .` sourced the script in this process. That was
strictly cheaper than `wrap` and it answered the wrong question. Retiring the factory had raised
one the plan had not: not *how* should the exe carry applications, but *should it*. It should not,
and all five were deleted. **`mt.exe` ships the Tcl/Tk libraries, the prelude and its own docs;
resolution is builtin verb → curated tool, as it was.** [The register](direction.md) carries the
reversal and its reinstatement in full.

Two things only building it could have shown, and both outlived it — they are why
[`tcl`](palette.md) works the way it does:

- **`Tcl_Main` reads its startup script before it calls `AppInit`.** The neat implementation is to
  let the dispatcher rewrite `argv0` to the tool's script and hand it back to `Tcl_Main` — and it
  cannot work, because by the time `AppInit` sources the prelude, the decision about what to
  evaluate has been taken. The process still tries to read a file called `sums`, and says so.
- **The event loop had to be replaced, not skipped.** Four of the five tools are Tk and not one
  calls `vwait`: under `tclsh`, `package require Tk` hands `Tk_MainLoop` to `Tcl_SetMainLoop` and
  `Tcl_Main` runs it *after* the script returns. Source a windowed tool with nothing after it and
  it builds its window, returns, and the process ends before one event is dispatched. `tkwait
  window .` is that loop for a program with one main window. Verified end to end while the tools
  were still here: `mt life --seed 41 --grace 2s` opened a real window, ran 131 generations,
  detected stasis, printed its JSON death line and exited 0.

**A decision was reversed and then reinstated inside one day**, and [the register](direction.md)
carries both rather than being quietly contradicted. Shipping tools inside the exe was refused on
2026-08-09 because `argv[1]` is fully allocated by `Tcl_Main` and the benefits had no receiver; the
dispatcher answered the first and the front door was the receiver, so it was reversed. Every step
of that was locally sound and it still landed wrong, because it never asked the question the
original entry had already identified as the real one — whether a front door should host
applications at all. It should not.

### And then the dispatcher lost its last heuristic

Step 2's rule kept a shape test: a first argument carrying a path separator or a `.tcl` extension
was handed back to `Tcl_Main` as a script, so `mt app.tcl` worked the way `tclsh app.tcl` does.
That was deliberately *not* "does this file exist" — but it was still a guess about which of two
kinds of thing you meant, made from how the word was spelled, and it left one case honestly
ambiguous: a file named `changes`, no extension, beside a shipped tool named `changes`.

**The first argument is now a name, with no test of any kind**, and a script is named by a verb:

```bash
mt tcl test/run_test.tcl
```

The cost was one word at **71 call sites**, paid once. What it bought is a dispatcher rule a
sentence long, which is the creed's *determinism over cleverness* reaching the last place the front
door was still guessing. Two consequences worth stating:

- **`mt app.tcl` no longer runs a script**, so machteld is no longer drop-in wherever a `tclsh` is
  expected. That was weighed and accepted: almost nothing here relied on it, and the property being
  bought is worth more than the one being given up.
- **Typing the old spelling teaches the new one.** `mt app.tcl` exits 127, and if what you typed
  looks like a filename — or is one — a second line says `mt tcl app.tcl`. That is the only place
  `file exists` appears, and it is in the message, never in the decision.

`tcl` is a palette verb like any other: in the manifest, with domain `TCL` and its own codes. It
does not return — the process *becomes* the script, taking its `argv0`, its `argv`, its event loop
and its exit code. Including a file in the program you are already running is Tcl's own `source`,
and always was.

**Next:** step 4 — strangle z command by command.

## The risk, named

**z.exe is the front door.** Rewriting what you use to enter the workspace, while using it daily,
is the most dangerous shape a project can have. Two things make it survivable: the commands are
independent, so this strangles rather than switches; and z already ships `verify`, `ledger`,
`mirror-restore` and `mirror-rehearsal` — the machinery for recovering this environment already
exists and is exercised.

Until step 4 finishes, `z.exe` stays exactly where it is and keeps working. machteld earns each
command by agreeing with z on it first.
