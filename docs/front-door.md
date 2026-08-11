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

## Step 1 is done: 275 of 275 agree

`test/front_agree.tcl` asks both front doors to resolve every curated tool and diffs the answers:
**275 / 275 agree, 0 differ, 0 refused, from the workspace root and from inside a project.** It
said **273 / 273** until step 4, and the two extra are the point: the list used to come from
machteld and now comes from z. See step 4 below for the four tools that were missing behind that
green number. It
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

## Step 4 has started: six commands, and two defects it uncovered

**The commands are reachable by their bare names.** Resolution gained a tier between builtin verbs
and curated tools, so `mt which rg`, `mt tools`, `mt projects`, `mt runtimes` work where
`z which rg` and the rest did — a front door that needs a prefix is not a replacement for one that
does not. It shadows nothing: all 21 of z's built-in names were checked against the 275 the
workspace curates and not one collides, and the suite re-checks that because the workspace gains
tools without asking anybody. The promoted set is read out of `front`'s own `set subs {...}` line,
which is the same line the manifest reads.

**The fidelity rule: the JSON must agree, the human text is ours.** `mt projects --json` and
`mt runtimes --json` diff clean against z's, compared as decoded values so indentation and key
order cannot lie. `which` and `tools` have no `--json` in z, so their plain text matches byte for
byte and `-json` was added as the shape a script wants. Both spellings of the flag are accepted —
the palette's `-json` and z's `--json` — which is what a strangler costs at the seam.

**The rules came out of z's source, not out of its output**, for the reason step 1 established. It
is not guessable that `runtimes` decides versioned-ness from a **hardcoded list of six names** in
`runtimes_builtin.go`: `zig` and `winsdk` each have a single version-shaped subdirectory and are
still reported unversioned.

### Two defects, and the second one is about testing

**machteld could not run four of the workspace's tools.** `EditPadPro8`, `RegexBuddy5`, `CSCSE5`
and `FNSE3` are `.z/t/<name>/` directories the manifest never mentions, and z runs them because
its inventory is *the `t/` directory scan* **∪** *the manifest's installed `exeFromRoot` entries*.
machteld read only the manifest, so all four were `notfound`.

It survived a month behind a green test. **`test/front_agree.tcl` enumerated `front tools` —
machteld's own list — so a tool machteld did not know about was never asked for.** A verification
that enumerates from the side under test can only find disagreements about things both sides
already name; it is structurally blind to anything missing. The list now comes from `z tools`, and
agreement went from **273 / 273** to **275 / 275** — a bigger denominator, which is the point.

**`file normalize` follows links.** `.z/r/winsdk` is a junction into Program Files, so normalising
the payload directory and a tool's executable put them in different trees and `signtool` stopped
counting as a winsdk alias — one row of fourteen. z uses `filepath.Clean`, which is purely textual,
and "is this path *written* underneath that one" is a question about names rather than about the
disk. Containment is lexical now.

### `status` is a cockpit, so it cannot come first

The plan lists `status` in step 4's read-only batch. **The code says otherwise**, and this is the
kind of ordering error only building it finds. `z status` aggregates four things, and three belong
to commands the plan defers to last:

| field | needs |
|---|---|
| `root`, `zGit`, `projects[].git` | git, and the project discovery already built — **done** |
| `mirror` | the mirror artefact index, keyed by physical directory identity, read through reparse-point-safe opens |
| `mirrorState` | the mirror run-state file and its process-liveness check |
| `deep` | `verify` and `ledger check`, neither of which exists yet |

So `mt status` lands **half built, and says so**. `root`, `zGit` and every project's git summary
diff clean against z — including the count rules, which are exact and slightly surprising: `??` is
tested first so an untracked file is never counted as anything else, then a `D` anywhere in the
two-character prefix, then an `M`, then `other`. A `MD` line is a deletion, not a modification.

**The missing keys are ABSENT, not null.** A caller diffing against z sees a key that is not there,
which is true, rather than a `mirror: null` that would be a claim — and there IS a report here, so
that claim would be false. `mt status -deep` is refused outright with `{MACHTELD FRONT unsupported}`
naming what it needs, the same way an `arg0` manifest entry *used to be* refused rather than
approximated — see below, where that refusal was closed.

### `arg0`, and a refusal that outlived its reason

`mt make` did not work. The workspace vendors GNU Make as `mingw32-make.exe` with `arg0: make` in
its manifest entry, and the front door refused the whole tool with `{MACHTELD FRONT unsupported}`
rather than run it under a name that would make `$(MAKE)` — and every recursive build — come back
wrong.

That refusal was right while the palette could not express the rename, and wrong the moment it
became permanent: a front door replacing z has to run what z runs. **The launcher needed no change
at all.** `wj_launch` has always passed the executable and the command line to `CreateProcessW`
separately, as `lpApplicationName` and `lpCommandLine`, so which file runs and what it calls itself
were independent from the first day. The missing piece was one option in the shared parser — which
is why `run`, `child start`, `detach` and `pty spawn` all take `-arg0`: all four spawn, and the
shared parser is where the option lives.

Applied **after** resolution, never before, so it is a rename and never a redirection:
`run -arg0 bash -- no_such_program.exe` still fails `notfound`, and the suite checks exactly that.
`mt make` now produces byte-identical output to `z make`, down to GNU Make's own `make:` prefix on
its directory messages — which is the observable proof that `argv[0]` took, since Make prints the
name it was called by. The resolution diff compares `arg0` alongside `exe`, `env` and `pre`, so a
rename that silently stops happening fails the same test that would have caught it never starting.

**Every key the workspace manifest uses is now honoured.** `preFromRoot`, `pre`, `envFromRoot` and
`arg0` were the refusal list, and it is empty.

### The project tier, and three defects in one paragraph

`in` looked like the smallest command left. It needed a **resolution tier machteld did not have**:
a project's `z.json` declares `commands`, and standing inside `_els`, `z build` runs that project's
build. `_els` alone declares eighteen; twelve projects declare 135 between them; machteld resolved
builtins and curated tools and then stopped.

The rule, read out of `project.go`: **argv[0] is resolved, not executed.** A name that is a curated
tool CLONES that tool's whole target — its environment overlay, its PATH shaping, its prepended
arguments — and the command's remaining words are appended to those. So
`["tclsh90", "tools/tasks.tcl", "build"]` runs the workspace's tclsh, with the workspace's Tcl
environment, on a project-relative script, from the project root. Otherwise argv[0] must be a path,
absolute or project-relative; a bare word that is neither is dropped rather than looked up on the
system `PATH`.

Diffing all 135 against z found three defects in that one paragraph:

- **The palette was consulted first, and `run` is a palette verb.** Ten of the twelve projects
  declare a `run` command, and `mt run` resolved to the palette's `run` in every one. z's reserved
  set is *its built-ins and its curated tools* — and machteld's equivalent of z's built-ins is the
  **front-door command set**, not the whole Tcl palette. `which` and `status` are the front door's;
  `run`, `json` and `hash` are scripting verbs that merely happen to be typeable. The palette tier
  moved to last, and `front run` is no longer promoted to a bare name at all: `mt run rg` was only
  ever `mt rg` with extra words, and z has no `run` built-in for the same reason.
- **`filepath.Join` cleans and `file join` does not.** `["./drang.exe"]` came out as
  `_drang\.\drang.exe` and `["../_drang/drang.exe"]` as `_exp\..\_drang\drang.exe`. Both run; both
  are the wrong string; both differed from z on nothing but punctuation.
- **The qualifiers were backwards.** `z:name` means *the kit's* name — a curated tool — and
  explicitly not a builtin, there being nothing to qualify a builtin against. machteld had `z:`
  reaching builtins and skipping tools, so `z:rg` did not resolve and `z:run` reached the palette.
  Never caught, because the agreement test had only ever asked bare names.

`front in <project> <name>` then falls out: find the project by name (leading underscore optional,
comparison case-insensitive), resolve in *that* project's context, run from its root with
`MT_PROJECT_ROOT` and `MT_PROJECT_NAME` set to it rather than to wherever the caller stands.

`test/front_agree.tcl` now diffs **275 tools and 135 project commands**, and fails if it finds
fewer than twenty of the latter — a count that silently drops to zero is the failure mode this
whole step keeps rediscovering.

### `verify`, and the one thing it must not match

`mt verify` reports the workspace's structural problems, and its list diffs **byte for byte**
against z's: the workspace root is meant to hold the front door, its private directory and hosted
projects, and nothing else. Five entries drift there today and both front doors name the same five.

It also reports what only the project tier could: a project command with an empty command line, a
command whose `argv[0]` is neither a curated tool nor a path, and a project defining a **reserved**
name. All three are *reported* rather than silently resolved one way — a name that means two things
is a bug in the workspace, not a precedence puzzle for the front door.

**The counts footer deliberately does not match**, and this is the first command where the fidelity
rule bites. z's footer counts its 21 built-ins; machteld's counts its own front-door commands, and
those are different sets on purpose. Matching it would mean claiming a builtin set machteld does
not have. The problems are the substance and they agree exactly; the tally is a footer and it is
ours. `-json` carries both, and z has no `--json` here at all.

**Both front doors are accepted at the root.** z flags anything it does not recognise, which will
include `mt.exe` the day it lands beside `z.exe`. For a while `z verify` will therefore report a
problem `mt verify` does not — that difference is the transition, not a defect in either, and it is
gated so it cannot be quietly lost.

### `scout`, and a cold cache that lied by a factor of ten

`mt scout` walks every underscore directory — all twenty-three, not just the twelve carrying a
project file, which is the whole point of the command: a directory meant to become a project and
never did shows up here as `no`. Its table is **identical to z's, line for line**, all twenty-nine.

**The interesting part was nearly a false claim.** The first timing said serial machteld ran in
1.15 s against z's concurrent 11.53 s, and "ten times faster than the Go one, without even using
concurrency" is a very quotable number. It was a **cold file cache** — the first `git status` across
twenty-three repositories reading from disk. On repeat runs:

| | median of 3 |
|---|---|
| `z scout` (concurrent) | 0.46 s |
| `z scout --serial` | 1.12 s |
| `mt scout --serial` | 1.17 s |
| `mt scout` (concurrent) | **0.56 s** |

So the truth is the opposite of the first reading: serial machteld matches serial z, and
**concurrency is worth 2.1×** — which is why z is concurrent by default and why `--serial` is not a
flag machteld could accept and quietly ignore. This is the second cold-cache misreading in this
project's history and the log records the first; the rule earned there is that a surprising number
is a reason to measure again, not to write it down.

The probes are **supervised children** — born in the job object, tree-killable, dying with the
front door, each carrying its own deadline — so a `git` that wedges on one repository cannot hang
the command or leak a process. That is the palette's own argument, applied to the front door's work.

`test/front_agree.tcl` now diffs five things: **275 tools, 135 project commands, the verify
problems, 29 scout lines** — and `cdirs`, which is the one entry that deliberately does not assert
equality. Its shape is in the `cdirs` section below.

### What is left, and what will not be built

Three of the remaining commands turn out not to be work at all, and one turns out not to be Tcl.

**`init` and `bom` do not exist.** Both are listed in z's built-in table and both answer *"planned
but not implemented yet"*. There is nothing to strangle.

**`logs` and `follow` belong to `mirror`.** Both read the mirror's robocopy logs and report
artefacts, through the same OneDrive resolution and artefact index that `status`'s missing half
needs. They land when `mirror` does, not before.

**`help` and `version` already exist** as machteld's own, answering about machteld rather than
about z, which is correct and not a gap.

So what genuinely remains of step 4 is **`mirror`, `ledger` and the shell shim** — the three the
plan always meant to do last — plus `logs`/`follow` and `status --deep` behind them.

**`ledger` is done** (below). What remains is **`mirror` and the shell shim** — and
`mirror`'s inner loop has now been prototyped and measured before committing to the port. It
answers the reservation this plan carried, and the answer is the opposite of the worry.

### `mirror`'s inner loop, measured before the port

The worry was that `mirror` (4,527 lines) is per-file work over large trees — the shape where Tcl's
per-operation cost bites — and that the honest ending would be a C program with a Tcl configuration
file, in which case Go was the better host and mirror should stay in z. So it was prototyped rather
than ported. The full experiment is in [`spike/mirrorlinks/RESULTS.md`](../spike/mirrorlinks/RESULTS.md);
the predictions were registered before the arms ran and all three held.

**There is no byte-copying loop.** `z mirror` drives `robocopy /MIR`; the copying, the retrying and
the deletion of destination extras are Windows'. What z itself does per entry is two tree walks —
a source link scan (run **twice** per mirror run, preflight and postflight) and a destination hazard
scan — and both ask Windows about **one path at a time**: `GetFileAttributes` per entry, plus a
`CreateFile` + `GetFileInformationByHandle` per entry on the destination side. Those walks are
**374 of mirror's 4,527 lines**. The other 4,153 are options, path pinning, run locks, state,
artefact indexing, reports, the restore manifest and rehearsal — glue.

On `C:\dev` — 21,860 directories and 280,794 files, **302,654 entries**, warm, minimum of three:

| | | per entry | |
|---|---|---|---|
| z's own Go loop | **14,081 ms** | 46.5 µs | |
| the same answer in C, bulk enumeration | **986 ms** | 3.3 µs | **14.3× faster** |
| C, unmodified — file entries discarded | 1,013 ms | 3.3 µs | |
| pure Tcl | *abandoned at 20 minutes* | | see below |

All three found the same two junctions, so this compares one answer three ways.

**Classifying every file costs nothing.** 986 ms against 1,013 ms is the build that classifies all
280,794 files coming out *marginally faster* than the one that throws them away — a 2.7% difference,
which is noise. `dirs.c:433` has been discarding data it already paid to read: the enumeration
returns each child's attributes **and**, for a reparse point, its tag in `EaSize`.

**Tcl is not the constraint, and the 20-minute run was a lie.** On one warm subtree where all three
arms completed, pure Tcl is **3.0× Go** — not 100×. The full-tree Tcl run showed 40 s of CPU in
16 minutes of wall time, 3% CPU, entirely blocked on I/O, and timing first-touch against
repeat-touch on the same 20,000 files gives **5,984 µs versus 46.5 µs — 128×**. It was measuring a
cold file cache. Warm, a Tcl `file` call and Go's `GetFileAttributes` cost the same, because they
are the same system call with different spelling in front of it: the Tcl **loop** costs 0.3 µs per
entry and the **call** costs 27 µs.

That is the cold-cache error for the fourth time in this project and the first time it was caught
before publication. What caught it was refusing a ratio without attributing it — the 0.3 µs loop
measurement made "Tcl is slow" impossible to believe.

**So: port it.** Not because Tcl can carry the loop at 3× — it can, and would not need to — but
because the loop belongs in C that **already exists**. A link scanner is `dirs.c` minus one filter
line, plus reading the reparse target for the handful of surrogates found (two in 302,654 entries).
The port makes a scan z runs twice per mirror run **14× faster**: 28.2 s of z's own per-entry work
becomes 2.0 s. And it is more faithful in one respect already visible — pure Tcl cannot tell a
junction from a directory symlink, and the C walk reads the tag.

### `ledger`, and a file two programs have to agree on to the byte

`mt ledger refresh` and `mt ledger check` maintain `.z/book/payloads.lock.json` and
`.z/book/msys2-packages.lock.txt`: the inventory that stands in for the gigabytes of payload the
workspace deliberately does *not* commit. Every curated tool, every runtime, the kernel's own Go
and Deno, their entrypoints with SHA-256 and size, the cached downloads that produced them, and
where each came from. `check` says whether the tree still matches, and exits 1 when it does not.

**This is the first command whose product is a file both front doors write**, and that changes what
agreement has to mean. Everywhere else machteld could render its own shape and diff the substance —
`runtimes` prints its own table, `verify` keeps its own footer. Here the output goes into a shared,
git-tracked file, so it must match `json.MarshalIndent` **byte for byte** or the two tools call
each other's output stale forever, and the workspace carries a file that is permanently wrong
according to whichever program did not write it last.

That means transcribing four Go behaviours no JSON writer would choose on its own:

- **Struct declaration order** — not alphabetical, not insertion order.
- **HTML escaping, on by default.** `json.Marshal` escapes `<`, `>` and `&` unless you use an
  `Encoder` with `SetEscapeHTML(false)`; z calls `MarshalIndent`, so a source URL with a query
  string comes out spelling its ampersand as a `\u` escape. Not one of the workspace's 275 tools
  has one today, so the real workspace could never have revealed this — the suite's fixture
  carries `?a=1&b=2` on purpose.
- **`omitempty` per field**, including `bytes` and `aliasCount`, where a zero disappears entirely.
- **`omitempty` on a struct does nothing.** `Restore` is tagged `omitempty` and is a struct, and
  `encoding/json` has no notion of an empty struct — so **every** payload carries a `"restore": {}`
  it does not need. The most visible Go-ism in the file, and the easiest thing in the world to
  leave out.

It matches. Machteld's 33,257 bytes are byte-identical to the 33,257 z produces, verified against
z's own `generateLedgerFiles` called directly rather than against the committed file — because the
committed file is **stale**, and has been since 18 July. The four payloads it is missing are
`EditPadPro8`, `RegexBuddy5`, `CSCSE5` and `FNSE3`: the same four `t/` directories the manifest
never mentions, and the same four machteld could not run until step 4 went looking. A ledger going
stale is not a defect in either program — it is a record of the tree changing — but it is a pleasing
coincidence that the workspace's own bookkeeping had been quietly out of date about exactly the
tools this project had already caught it forgetting.

**`generatedBy` still says `z ledger refresh`, and that is deliberate.** It names the *format's*
generator, and machteld is a second implementation of that command rather than a second format. The
one line that is **not** z's is the advice `check` prints when something is stale: z says
`run: z ledger refresh`, machteld says `run: mt ledger refresh`, because a front door replacing z
must not answer a problem by telling you to go and run z. That is a sentence addressed to a person,
not a byte in a shared file, and the agreement test asserts both halves — every other line
identical, that one different in exactly that way.

**And a verdict command finally exits like one.** `mt verify` printed five workspace problems and
exited **0** until this landed, so `mt verify && deploy` deployed on a broken workspace. `ledger
check` has the same shape, which is what forced the mechanism: a front-door command can now say
what the process should exit with, separately from what it returns. Not an error — `verify` finding
problems is a *successful* run of a command that looked and reported, and raising would make a
script `catch` a working command and print its verdict as a failure message. Reset at the top of
every `front` call, so the last command to run is the one whose verdict the process carries.

**Cost: 1.43× z**, and the whole of the remaining gap is measured rather than guessed.
`mt ledger check` runs in ~3.9 s against z's ~2.8 s, interleaved, five runs each. Both pay ~1.26 s
for `pacman -Q`, a subprocess neither can avoid. Assembly is ~440 ms. The rest is SHA-256 over
**973 MB across 55 files**, and machteld's `hash` runs at **598 MB/s** against Go's
hardware-accelerated implementation — that difference alone is roughly the whole 1.1 s. It is a
`src/hash.c` question rather than a ledger one, and it is recorded here rather than fixed.

Getting there cost one optimisation worth naming, because its shape will recur. The first working
version spent **1.3 s of its 3.5 s inside `FrontClean`** — called **212,000 times over ~1,500
distinct strings**, because containment is asked once per (payload, tool, candidate path) and both
sides get cleaned every time. `FrontClean` is a purely lexical function of its argument, so
memoising it needs no invalidation key at all, unlike `manifest`'s memo. Measured same-build with
hashing stubbed out, to keep its 900–1400 ms of variance out of the number: **1,254 ms → 426 ms,
2.82×**. The first end-to-end A/B showed the change making things *slower*, because hashing
variance and background load swamped an 810 ms effect — the cold-cache lesson, met a third time.

### `cdirs`, and the first command that must NOT agree with z

**This section replaced a refusal.** It used to say `cdirs` "wants a C verb **or** it stays outside
machteld", and the register said the same in more detail: a Tcl walker managed 96% of `C:\dev` in
12.2 s against z's 1.5 s, wrong three times in three different silent ways. That reasoning was
sound and it has been overtaken twice — first by `src/dirs.c`, which is the C verb the first branch
named, and then by a decision that quality matters more than conformance with z. Both halves of the
old sentence are now false, so the sentence is gone rather than left standing beside the command it
denies. A shipped doc refusing something the shipped binary does is exactly the drift these files
are gated against, and [the suite](../test/run_test.tcl) now fails if that sentence comes back while
`cdirs` is a promoted command.

```
mt cdirs                           # the workspace, into $MT_HOME/cache/mt/dirs/<slug>.txt
mt cdirs C:/Users/anafa            # any root you name
front cdirs $d -depth 3 -prune {node_modules .git} -out list.txt
```

**`cdirs` was deferred once more after `dirs` landed, and the reason was a doctrine.** The register
put it plainly: `mt cdirs` "would also have had to default to `C:/`, where the surrogate rule makes
machteld and z disagree by design, against a doctrine that says machteld earns each command by
agreeing with z on it first." That doctrine has served every command up to here — 275 tool
resolutions, 135 project commands, 5 verify problems, 29 scout lines, all agreeing exactly — and it
is now **overruled for this one command**, for two reasons. Agreement was only ever a proxy for
correctness; and where the two disagree, it is measured that machteld is right.

**The measurement, on this machine, both walkers reading the same disk minutes apart:**

| | directories | wall (warm) |
|---|---|---|
| `z cdirs --root C:\Users\anafa` | 112,018 | 13.3 s |
| `mt cdirs C:/Users/anafa` | 236,162 | 21.8 s |
| only in `mt` | 124,144 | every one under `C:/Users/anafa/OneDrive` |
| only in `z` | 0 | |

236,162 − 112,018 = 124,144, and only-in-z is 0: **the four numbers are one measurement and they
add up.** The version this table replaced did not — 236,150 − 112,007 is 124,143 against a
published 124,144 — which is the wrong error for an entry whose thesis is "measured rather than
asserted". Both walks are warm repeats, each after a discarded first run, minutes apart. The totals
move a little between runs because a home tree churns; the 124,144 has not moved in any run.

Every one of the 124,144 extra directories is under **one** reparse point,
`C:/Users/anafa/OneDrive`, tag `0x9000701a`, surrogate bit clear — a Files-On-Demand root, which
virtualises file *contents* and not folders. They are real local directories. z omits them because
it refuses to descend anything carrying `FILE_ATTRIBUTE_REPARSE_POINT`; `dirs` refuses only *name
surrogates*, which junctions and symlinks set and a cloud root does not.

**The defect is not that z stops. It is that z's report cannot tell you it mattered.** Its stats
line says `12 links skipped` and names none of the twelve; eleven of them are junctions where
stopping is right and one of them is more than half the home tree. So `cdirs` is the first command
where the fidelity rule inverts: **the JSON must not agree, and the report is the point.** A
refusal the walker made is NAMED, a refusal the caller asked for is COUNTED, and `[COMPLETE]` or
`[PARTIAL]` sits on the first line beside the count so the count cannot be read alone. The full
shape is in [the palette](palette.md).

**And "the report is the point" is a claim that has to be met, not asserted.** The first version of
it named the place and gave no number — *named, magnitude invisible*, which is worth what z's
*counted, consequence invisible* is worth — and it printed `Everything under it IS in the count
above` unconditionally, including on the `-depth 3` walk where ~124,000 directories under that very
row are absent. A report telling a reader the list is complete below a place where it is not is
this project's own failure shape, in the mechanism built to end it. Both are fixed: every `entered`
row now carries how much of the answer came from under it, and the completeness sentence is
conditional on nothing having been pruned, cut or refused below that row.

**Two more deliberate divergences, both of which would be silent if they were not written down.**
The default root is `MT_ROOT` and not `C:\` — the front door's subject is the workspace, and it
puts the zero-argument form on the one root where machteld and z *do* agree exactly (21,804
against 21,804 on `C:/dev`, an active build tree whose count moves while the agreement does not),
so the disagreement only ever happens in a request somebody typed. And
the default output path is `$MT_HOME/cache/mt/dirs/<slug>.txt`, never z's
`cache/cdirs/c-drive-dirs.txt`: during the transition `MT_HOME` *is* `.z`, the lists are
forward-slashed where z's are backslashed, and writing 2.1× as many lines into the file z's own
cache readers open would be the silent substitution this command exists to end.

**`test/front_agree.tcl` therefore gained its first entry that asserts something other than
equality** — a superset with a named cause, on two subjects, because either alone is satisfiable by
a defect. On `C:/dev`, where no non-surrogate reparse point exists, the two rules coincide and the
lists must be **equal both ways**: that is the bound, and a walker that descended junctions would
pass every superset clause and fail here. On the home tree the claim is z ⊆ machteld, the excess
non-empty, every extra below a directory machteld itself classified `surrogate 0, descended`, and
every extra probed for existence with Tcl's own `stat` — a third implementation, asked one path at
a time, because set arithmetic between two walkers is equally satisfied by a walker that *invents*
paths.

**And the oracle had to be fixed before it could be believed.** `z cdirs --stdout` read back through
`run` is capped at 1 MiB (`src/proc.c`, `size_t cap = 1u << 20`) and truncates in **silence**:
measured here, `--max-depth 6` printed 16,817 lines and `run` returned 16,423, exit 0, with
`truncated` set to `out` and nobody looking. The 394 lost lines come back as 394 extras
attributable to nothing — and truncation makes a *superset* gate pass **harder**, which is this
project's recurring failure shape in its purest form: a gate strengthened by its own bug. z's list
is read from `--out FILE` now, and the line count is cross-checked against the count in z's own
stats line.

### And the front door's own commands, since they are what `mt` answers

```
mt roots                           # where the workspace is, and which private directory was found
mt which rg                        # name, kind, executable
mt env rg                          # the whole resolution as a dict; -json for the wire
mt tools ?pattern?                 # what the workspace curates
mt projects  ·  mt runtimes  ·  mt status  ·  mt verify  ·  mt scout  ·  mt journal
mt in els build                    # resolve and run a name in a project's context
mt cdirs                           # the directory index
```

`mt roots` was the first of these to exist and the last to be written down here, which is how the
suite came to gain a gate for it: the doc-accuracy check runs doc → code and nothing ran
code → doc, so a promoted command could ship undocumented and nothing said so. It fails now if any
name in `front`'s own `set subs {...}` line is missing from this file. `run` is deliberately not in
that list — see the resolution section above.

## The risk, named

**z.exe is the front door.** Rewriting what you use to enter the workspace, while using it daily,
is the most dangerous shape a project can have. Two things make it survivable: the commands are
independent, so this strangles rather than switches; and z already ships `verify`, `ledger`,
`mirror-restore` and `mirror-rehearsal` — the machinery for recovering this environment already
exists and is exercised.

Until step 4 finishes, `z.exe` stays exactly where it is and keeps working.

**machteld earned every command up to `cdirs` by agreeing with z on it first, and that rule is now
retired rather than quietly broken.** Agreement was only ever a proxy for correctness, and `cdirs`
is where the proxy and the thing part company: 124,144 real local directories that z's rule omits
and z's stats line cannot mention. The gate that replaced it is stronger, not weaker — a superset
with a named cause, on two subjects, one of which still demands exact equality both ways. Where a
command *can* agree with z it still must, and `front_agree.tcl` fails if it stops.
