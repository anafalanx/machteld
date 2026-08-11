---
type: log
title: Change log
description: Update history for the machteld knowledge bundle and build.
tags: [machteld, log]
timestamp: 2026-07-09
---

# Log

## 2026-08-11 — `ledger`, and a verdict command that finally exits like one

**`mt ledger refresh|check`** maintains `book/payloads.lock.json` and `book/msys2-packages.lock.txt`
— the content-addressed inventory that stands in for the gigabytes of payload the workspace
deliberately does not commit. It is the first command whose product is a **file both front doors
write**, so agreeing on the facts is not enough: it has to match `json.MarshalIndent` byte for byte,
or whichever tool ran second calls the other's output stale forever. It does — 33,257 bytes
identical to z's, checked against z's own `generateLedgerFiles` rather than against the committed
file.

Four Go behaviours had to be transcribed, and one of them the real workspace could never have
revealed: `encoding/json` **HTML-escapes `<`, `>` and `&` by default**, and not one of the 275
curated tools has a query string in its source URL. The suite's fixture carries `?a=1&b=2` for that
reason. The others: struct declaration order, `omitempty` on numeric fields, and the fact that
`omitempty` **does nothing to a struct** — which is why every payload carries a `"restore": {}`.

**`mt verify` exited 0 on a workspace with five problems**, so `mt verify && deploy` deployed.
`ledger check` has the same shape and forced the fix: a front-door command can now report an exit
code separately from its return value. Deliberately not an error — a command that looked and found
problems ran successfully, and raising would make a script `catch` a working command.

**1.43× z, and the gap is not the port**: ~1.26 s of both runs is `pacman -Q`, and the remainder is
SHA-256 over 973 MB at 598 MB/s against Go's hardware-accelerated implementation. One optimisation
landed on the way — `FrontClean` memoised after it was measured at **212,000 calls over ~1,500
distinct strings**, 1,254 ms → 426 ms — and the first end-to-end A/B of it said, wrongly, that it
made things slower. Hashing variance swamped an 810 ms effect. That is the cold-cache lesson for
the third time, and it now has a narrow statement in [direction](direction.md): an end-to-end
number cannot measure a component smaller than its own variance.

809 checks pass. Six mutations were run against the new gates and each failed exactly its own
checks; two of them are caught **only** because the golden fixture carries a payload with no
manifest entry and a capital letter.

## 2026-08-11 — the walk goes to C, `cdirs` diverges on purpose, and `mt make` finally runs

**`dirs`** is a C verb now: a `GetFileInformationByHandleEx` walk that classifies reparse points
by their name-surrogate bit rather than by a list of tags it happens to know, so a tag nobody has
seen yet is classified by the rule Windows publishes instead of by omission. It lists exactly what
z lists, in 0.77× of z's time.

**`front cdirs` is the first command that must NOT agree with z**, and the divergence is the
point: z's walk stops at OneDrive, so it never names **124,144 directories that are on the disk**.
Agreement was the wrong target once quality was, and the gate now proves a *superset* — every path
z found, plus extras that were probed and found real, with every extra attributable to a disclosed
root. Both are argued at length in [direction](direction.md), which is also where the four defects
review found *in* `cdirs` are written down.

**`mt make` works.** It was refused outright with `{MACHTELD FRONT unsupported}` because the
workspace vendors GNU Make as `mingw32-make.exe` with `arg0: make`, and the palette had no way to
say "run this file under that name" — so a makefile asking `$(MAKE)`, and every recursive build,
would have come back spelled wrong. `-arg0` is now a shared spawning option (`run`, `child start`,
`detach`, `pty spawn`), applied **after** the program is resolved so it renames and never
redirects: `run -arg0 bash -- no_such_program.exe` still fails `notfound`. The launcher needed no
change at all — `wj_launch` has always passed `CreateProcessW` the executable and the command line
as separate arguments, so which file runs and what it calls itself were independent from the first
day. `mt make` and `z make` now print the same bytes, down to Make's own `make:` prefix.

**Every key the workspace manifest uses is honoured**: `preFromRoot`, `pre`, `envFromRoot` and
`arg0` were the refusal list, and it is empty. 759 checks pass; the resolution diff agrees on all
275 tools and all 135 project commands.

## 2026-08-10 — step 4 begins, and finds four tools machteld could not run

Six of z's commands are now reachable by their bare names — `mt which`, `mt env`, `mt tools`,
`mt projects`, `mt runtimes`, plus `roots` and `journal` — through a resolution tier between
builtin verbs and curated tools. Nothing is shadowed: all 21 of z's built-in names were checked
against the 275 the workspace curates and none collides, and the suite re-checks it live.

`projects` and `runtimes` are new; their `--json` diffs clean against z's, compared as decoded
values so indentation and key order cannot lie. `which` and `tools` now print z's plain text byte
for byte and gained a `-json` z never had. The rules came out of **z's source**: it is not
guessable that `runtimes` decides versioned-ness from a hardcoded list of six names, and `zig` and
`winsdk` each have a single version-shaped subdirectory and are reported unversioned anyway.

**machteld could not run four of the workspace's tools.** `EditPadPro8`, `RegexBuddy5`, `CSCSE5`
and `FNSE3` are `.z/t/<name>/` directories the manifest never mentions. z's inventory is the `t/`
directory scan **∪** the manifest's installed `exeFromRoot` entries; machteld read only the
manifest, so all four came back `notfound`.

**It survived a month behind a green test, and the reason generalises.** `front_agree.tcl`
enumerated `front tools` — *machteld's own list* — so a tool machteld did not know about was never
asked for. A verification that enumerates from the side under test can only find disagreements
about things both sides already name; it is structurally blind to anything missing. The list now
comes from `z tools`: agreement went from 273/273 to **275/275**, and the larger denominator is
the whole of the improvement.

**`file normalize` follows links.** `.z/r/winsdk` is a junction into Program Files, so normalising
a payload directory and a tool's executable put them in different trees, and `signtool` stopped
counting as a winsdk alias — one row of fourteen. z uses `filepath.Clean`, which is purely
textual. "Is this path *written* underneath that one" is a question about names, not about the
disk; containment is lexical now.

468 checks pass.

## 2026-08-10 — the front door was 40× slower than z, for one line

`mt version` answered in **361 ms**; `z.exe version`, the Go front door it is replacing, answers in
**9.9**. `mt front which rg` took **704 ms** against z's **31**. Both are now **25.6 ms** and
**28.8 ms** — resolution is *faster* than z's — and the whole of it was one line.

**Where the time actually went**, measured by building host variants that isolate each part:

| | median |
|---|---|
| `tclsh90s`, a reference static Tcl, running a trivial script | 18.6 ms |
| the same through a machteld host with an **empty** prelude | 22.6 ms |
| ditto **with both basekits embedded** | 22.3 ms |
| parsing the whole 101 KB prelude | **2.3 ms** |
| reading and JSON-decoding the 162 KB workspace manifest | **1.5 ms** |
| **`manifest` — deriving the palette's self-description** | **316 ms** |

`FrontResolve` opened with `dict exists [manifest] $name`, to ask whether a name was a builtin.
That is the right question asked in the most expensive possible way: `manifest`'s Tcl half runs
`MtclFacts` over all 13 Tcl-written verbs, and `MtclFacts` follows helpers transitively with a
regexp per helper per body. **Every `mt <name>` rebuilt the entire palette description before it
could look anything up.**

Two small changes. `manifest` memoises its derivation, keyed on the `::machteld::*` command set so
a script that defines a new verb still gets a fresh answer rather than a stale one. And
`FrontResolve` asks `PaletteVerb` — the same predicate `manifest`'s own loop uses, so there is
still exactly one definition of what counts as a verb. Both are gated structurally rather than by
timing: the suite fails if `FrontResolve`'s body mentions `manifest` again, and if `PaletteVerb`
and the manifest's key set ever disagree.

**A correction, because a wrong number was published.** The entry below reports the embedded
basekits costing **130 ms**, with a table. That measurement was contaminated: it compared two
builds that differed in more than their basekits, and attributed to file size a cost that was
really `manifest`. A same-session A/B of two hosts built from the same prelude puts the basekits at
**~13 ms**, and the conclusion drawn from the bad number — that a large appended archive slows
startup as a step — is **withdrawn**: null-prelude hosts of 6.25 MB and 10.68 MB answer in 22.6 ms
and 22.3 ms, which is no difference at all.

What survives is the shape of the mistake, which is worth more than the number was: **a
cross-build A/B is not an A/B.** Two artefacts differing in one *intended* way can differ in
others, and the measurement will cheerfully attribute the whole gap to the thing you were thinking
about when you made it.

The 25.6 ms that remains is a Tcl interpreter starting up, and z.exe's 9.9 ms is a Go binary not
having one. That gap is inherent, and small enough to stop looking at.

**And the suite went from 38.3 s to 24.5 s**, medians of three runs, measured the same way — by
reintroducing the one line, rebuilding, and timing both. Almost every check spawns a child through
`mt tcl <script>`, and every one of those children was deriving the palette description before it
could work out that `tcl` was a verb. A third of the suite's wall-clock was the front door
introducing itself to itself, once per process.

## 2026-08-10 — `wrap` comes back, and the front door pays 130 ms for it

> **The 130 ms in this entry's title is wrong — it is ~13 ms.** See the entry above for the
> measurement that corrected it and for what was actually slow.

A receiver turned up, and it is the one the refusal said did not exist. At work, a small tool
written in an afternoon has to reach colleagues through a shared SMB folder — machines with no Tcl,
no Python and no install rights. One self-contained exe on a share is the whole answer, and that is
precisely what `wrap` produces. Both bare hosts are back inside `mt.exe`, console and GUI, so the
exe alone can stamp with no toolchain and no workspace.

**Measured rather than assumed, because the prediction was wrong.** I expected embedding to cost
nothing — an unread part of a file is never paged in — and `mt version`, a builtin answered
in-process, says otherwise:

| build | size | median of 40 |
|---|---|---|
| no basekits | 5.99 MB | 237–254 ms |
| both basekits | 10.21 MB | 362–378 ms |
| 4.6 MB × 2 of random data | 14.77 MB | 359 ms |

**+130 ms on every invocation**, reproducible with the builds interleaved. And not an antivirus
reaction to executables nested in an executable, which was the obvious hypothesis: incompressible
random data of greater total size costs the same, so it is the appended archive's size and it
behaves like a step rather than a slope. The cheap alternative — basekits in `.mt/r/`, since they
never need to travel — was offered and declined in favour of one file that can stamp anywhere.

**Restoring it needed one thing that only building it could have shown.** A stamped tool's `argv0`
is its own `main.tcl` inside its own zipfs, so under "the first argument is a name" the front door
resolved that path as a tool name and exited 127 before the program ran. The old shape test had hid
this by accident — a zipfs path has separators, so it was handed straight back. The dispatcher now
stands aside when it finds a root `main.tcl` in a mounted archive, which is exact rather than a
guess: `tools/package.tcl` fails the build if one ever lands in `mt.exe`'s own archive, so the two
halves assert the same fact from opposite sides. Verified by removing the check and watching three
gates fail.

453 checks pass.

## 2026-08-10 — no applications ship inside it

`changes`, `tasks`, `sums`, `life` and `lifelab` are gone from the tree, along with the resolution
tier that found them and the window test that drove one. `mt.exe` carries the Tcl/Tk libraries, the
prelude and its own docs; resolution is **builtin verb → curated tool**, as it was before this
morning.

**The reasoning is one line.** A front door resolves names and supervises what it starts. Hosting
the applications as well makes it two things at once, and the second grows without limit — every
program added is another name competing with the workspace's own 273, permanently.

**The interesting part is that the entry below is wrong, and every step of it was sound.** Retiring
`wrap` reversed a refusal recorded the previous day, and the reversal answered each stated
objection honestly: the mechanical one had genuinely been solved by the argv dispatcher, the
benefits had genuinely acquired a receiver, and the cost had genuinely moved the other way. What it
never asked was whether a front door should host applications *at all* — a question the refused
entry had itself flagged as the real one, in the paragraph the reversal quoted while getting it
backwards. **Answering a different question well is a failure mode that looks exactly like being
right**, and the only thing that catches it is going back to what the register said the question
was.

What the tools taught outlives them, which is why they were worth having. `changes` and `tasks`
named the C capabilities they needed, and that is where `watch` and `mtps` came from. `sums` proved
the exe can spawn copies of itself as a pool of persistent workers. `life`/`lifelab` were the
stress experiment that found the cap-enforcement and `child wait -timeout` defects. And the two
facts about `Tcl_Main` found while making them run in-process are why [`tcl`](palette.md) works the
way it does.

`mtps` loses its only in-repo caller and **stays**: it is a machine-control primitive, the half
`child list` is not, and the journal's planned reconciliation sweep has no other mechanism. Rule 5
says an unused verb is a question to answer deliberately rather than let sit — asked, and answered.
The suite covers it directly (27 checks), so nothing became untested when `tasks` left. 441 checks
pass; 273 of 273 resolutions still agree with z.

## 2026-08-10 — the factory is retired: 10.2 MB → 6.0 MB

Step 3 of [the front-door plan](front-door.md). `wrap`, both embedded bare hosts, the GUI
`WinMain` host, `tools/pack.tcl` and the tool-stamping loop at the end of the build are gone. The
build used to finish by running the exe it had just produced five times, turning five tool
directories into five 5.9 MB standalone exes; it finishes when the exe is built now.

**The five tools rode inside `mt.exe`** at `//zipfs:/app/tool/<name>/main.tcl` for a few hours,
with resolution gaining a tier — builtin verb → shipped tool → curated tool — so `mt sums .`
sourced the script in this process. **Then all five were deleted from the project**, later the same
day, and the tier with them. See the next entry; what follows is what was built before that.

Two things only building it could have shown:

- **`Tcl_Main` reads its startup script before it calls `AppInit`.** The neat implementation is to
  have the dispatcher rewrite `argv0` and hand the script back to `Tcl_Main`; it cannot work,
  because the decision about what to evaluate has already been taken by the time `AppInit` sources
  the prelude. The process still tries to read a file called `sums`, and says so.
- **The event loop had to be replaced, not skipped.** Four of the five tools are Tk and none calls
  `vwait`: `package require Tk` hands `Tk_MainLoop` to `Tcl_SetMainLoop` and `Tcl_Main` runs it
  after the script returns. Source a windowed tool with nothing after it and it builds its window,
  returns, and the process ends before one event is dispatched. `tkwait window .` is that loop
  here. `mt life --seed 41 --grace 2s` opens a real window, runs 131 generations, detects stasis,
  prints its JSON death line and exits 0.

**And the dispatcher lost its last heuristic.** Step 2 had kept a shape test — a first argument
carrying a path separator or a `.tcl` extension was handed back to `Tcl_Main`, so `mt app.tcl` ran
a script the way `tclsh app.tcl` does. It was deliberately not "does this file exist", but it was
still a guess about what you meant made from how you spelled it, and putting five tools in the exe
made its one ambiguous case concrete: a file named `changes` beside a shipped tool named `changes`.
**The first argument is a name now, with no test at all**, and a script is named by a verb — `mt
tcl test/run_test.tcl`. That cost one word at 71 call sites, once, and cost machteld the property
of being drop-in wherever a `tclsh` is expected. `tcl` is an ordinary palette verb (domain `TCL`,
in the manifest) that does not return: the process becomes the script, taking its `argv0`, `argv`,
event loop and exit code. Typing the old spelling exits 127 and names the new one on the second
line — the only place `file exists` appears, in the message and never in the decision.

**A name is joined onto a directory here, which nothing else the front door resolves is** — every
other name is a key in a dict the workspace wrote. The zipfs resolves `..` (checked: `file exists
//zipfs:/app/tool/../tool/sums/main.tcl` is 1), so without a name check `mt ../tool/sums` would
have found a real tool, and enough `..` would have walked out of the archive onto the disk. A
shipped tool's name is letters and digits or it is not one, and the gate uses spellings that
*would* resolve rather than ones that would have failed anyway.

**One decision was reversed**, and [the register](direction.md) records it rather than being
quietly contradicted: shipping tools inside the exe was refused on 2026-08-09, because `argv[1]` is
fully allocated by `Tcl_Main` and the claimed benefits had no receiver. The argv dispatcher built
in step 2 answered the first — it broke no spelling that worked — and the front door is the
receiver.

`front which` now answers with the script for a shipped tool rather than the exe that sources it,
`front tools` lists them beside the curated ones, and `test/front_agree.tcl` excludes them from the
z comparison by name rather than reporting five deliberate differences as five surprises every run.
474 checks pass; 273 of 273 resolutions still agree with z.

## 2026-08-09 — the worker pool: persistent workers, and a tool that spawns itself

Six steps, each ending in something that builds and passes. The design and the refusals that
shaped it are in [parallelism](parallel.md); the plan, including what previous work had to change,
is in [the pool plan](pool-plan.md).

**`child start -channels`** — the only new C. A child launched this way keeps its stdin write end
open, does not start the capture reader threads, and hands its three pipes to Tcl as channels.
Every supervision guarantee still applies, which is the entire reason this is a verb rather than
`open |cmd r+`: the worker is born in a job object, dies with its parent, is tree-killed, capped,
and reaped by `scope`. The hazard flagged as most likely to sink the step did bite — Tcl closing
a channel and `child_free` closing the same handle is a double-close, and on Windows that is a
crash, not an error — so the handles are nulled the moment Tcl owns them.

It also uncovered a **pre-existing lie**: `child start -timeout` was accepted, documented in the
manifest, and *ignored*; `child wait` always waited forever. A deadline is now stored at launch
and the earlier of the two wins.

**`worker`** — the far side. A handler is a proc and its argument list is the request schema, so
the protocol documents itself and `worker ops` can answer what a worker accepts. That is not a
style preference: the same loop at top level runs 3.6× slower, so a design inviting top-level
handler bodies would hand most of the parallelism straight back.

**`pool`** — supervision, which was the one thing the spike deliberately did not prove. Requeue on
worker death, poison after `-maxtries`, results in submission order, and `chan event` throughout so
a director never polls.

**`pmap`** — the whole thing in one call. It closes the pool on **every** path, including the
raising one, and re-raises a worker's failure carrying **the worker's own errorcode**. That is the
error contract having travelled the whole way: raised in one process, `trap`-able in another.

### `sums`, and a 38× speedup that was not one

The end-to-end proof is a tool: `sums` hashes a tree using copies of *itself* as workers
(`sums.exe --worker`), which is one artefact with no tclsh and no worker script on disk. It is also
the first shipped tool that is not a window, so it exercises `wrap --console`.

Its first measurement reported sequential 73.6 s against a pool at 1.9 s — **38×**, on twelve
logical cores. The comment above that code said sequential ran first *so the pool could not
inherit a warm cache*, which is exactly backwards: the first pass pays for every cold read and for
the antivirus filter's first look at each file, and the second reads from the OS cache. Running
first is a penalty. With a discarded warm-up pass and both halves timed warm, the same tree gives
**1.27×** — and **0.38×** at width 1, which is the protocol's cost with no concurrency to pay for
it, printed rather than hidden.

On a gigabyte in 272 files the ordering across four digests is the finding: `md5` **3.51×**,
`sha512` 2.75×, `sha1` 2.72×, `sha256` **2.34×**. The fastest digest parallelises worst, because
this CPU hashes sha256 in hardware and what remains is reading, which does not parallelise.
Hashing is a bandwidth problem wearing a CPU problem's clothes.

### What the realignment step found

`execution-model.md` still pointed the callback layer at the cockpit, removed hours earlier; it
now points at `pool` and Tk, and the **two ways to wait** are a table rather than folklore —
blocking verbs wait for a process, the event loop waits for data, and a blocking verb does not
pump the event loop.

The plan's own prescription for the namespace trap turned out to be the weaker fix. Rather than
asking authors to remember a `namespace path`, `worker on` now compiles a handler **in the
namespace where it was written**, so it calls that file's procs by bare name like every other line
around it — moving the failure from late-and-remote (a per-item reply from another process) to the
ordinary one, hit on the first line. Underneath it, a claim `palette.md` has made since the
beginning is finally gated: **every verb resolves by its bare name**, so a future verb called
`close` or `format` fails the suite instead of being silently answered by Tcl's command.

### Three defects, each found by breaking something on purpose

- A break-test aimed at `pmap`'s errorcode passthrough fired two checks it was not aimed at, and
  following them up showed `pmap` could raise `{MACHTELD PMAP failed}` while declaring only
  `badvalue usage`. The code had been assembled into a **variable**, and `-errorcode $code` is
  invisible to both the manifest derivation and the registry scan, which match literals. An
  errorcode built at runtime is invisible to derivation.
- Reverting the handler namespace made the new gate fire — and **abort the run**, because with the
  regression in place the handler was not there to call, so every check after it silently never
  ran. That is the same failure this suite has learned three times (`wres`, `pres`, `pwait`);
  `valof` is the general form.
- `parallel.md` claimed `child` could not feed a running child. Step 1 had closed it. Note what
  closing it did *not* need: a `child send` verb. Handing the pipes to Tcl gives `puts`, `gets`
  and `chan event` at once, where a verb would have re-implemented one of them.

## 2026-08-09 — `log`, and Phase 1 complete

The last of the three categories machteld had entirely empty. It matters more here than the count
suggests: running things unattended is the whole premise, and a `detach`'d daemon had nowhere to
write at all.

`log configure / debug / info / warn / error`, levels ordered with `off` to silence, output to a
channel or an appending file, and structured pairs after the message:

```
2026-08-09T15:53:06.832 INFO  watching dir=C:/dev/_machteld count=3
```

**A write failure never throws**, and that decision shapes everything else. A wrapped GUI exe
starts with no standard channels, so `puts stderr` raises there — and a log call that can throw
kills the program at whatever arbitrary point it was asked to record something. A failed write
increments a counter and `log configure` reports it: the same bargain `watch` already makes with
`dropped`. Losing data silently is unacceptable, so it is counted; it does not become an
exception in the middle of unrelated work. Removing the guard fails four tests.

Pairs are structure rather than decoration — creed 2 says machine-legible and human-legible
should be the same thing, and a log line is where that is most often abandoned. A dangling key
renders `key=?` rather than raising: the caller's mistake must not cost the message, which is
being written precisely because something is already going wrong.

Two smaller decisions worth their lines. `-file` **appends**, because a tool restarting must not
erase the record of why it restarted. And changing the sink closes the channel `log` opened — not
tidiness but necessity: Windows refuses to delete an open file, so a leak would lock the log for
the life of the process. The suite's own reset only works because of it, which is why it is also
asserted directly.

### Phase 1 is complete

`hash`, `cli` and `log` — the three categories present in Python, Go and Deno alike and absent
here. The palette stands at **18 verbs**, four of them Tcl-written with full manifest facts
(domain, codes, options, subcommands), which is Phase 0 paying for itself: each of these landed
already describing itself, with nothing retrofitted.

## 2026-08-09 — `cli`: declare a tool's arguments once

Second of the three empty stdlib categories. Argument parsing exists in every standard library
there is — `argparse`, `flag`, `cli` — and machteld, a **tool factory**, had none, so every program
it stamped wrote its own.

Two design decisions did the work:

- **It is pure: prints nothing, never exits.** An argparse-style "print usage and exit" is
  invisible exactly where it matters most — a wrapped GUI exe starts with **no standard channels
  at all**, so a tool reporting a bad argument on stdout reports it to nowhere. `tasks` learned
  that the hard way earlier today. `--help` comes back as a value; a bad argument raises
  `{MACHTELD CLI usage}` whose message already carries the usage block.
- **The spec is a dict, not a mini-language.** `{--interval int 2000..}` would mean inventing
  syntax to parse, which rule 1 exists to prevent. `min`, `choices` and whatever comes next are
  ordinary keys.

Two codes, because two different people make the mistakes: `usage` is the user's (unknown option,
missing value, out of range), `badvalue` is the author's (unknown attribute, unknown type, a name
declared twice). A tool shows the first and should fail on the second.

`tasks` was moved onto it, which is the real test: all ten of its existing argument tests still
pass, its hand-rolled `lsearch` parsing is gone, and it gained a `--help` it never had.

### A Tcl dict hides a duplicate key

`{--x {...} --x {...}}` does not collide — the dict simply keeps the last, and the first
declaration vanishes with its type and default, silently. The only place that is still visible is
before the dict exists: `llength $spec` against `2 * [dict size $spec]`.

### And a vacuous gate, caught by breaking it

The missing-value check — the whole reason this verb exists — was covered by a test that could
not fail. Removing the check entirely left the suite green, because `--interval` is typed `int`
and the *type* check rejects an empty value anyway, producing the same `{MACHTELD CLI usage}`. The
test asserted the code, not the behaviour.

The case that actually mattered was a **string** option, where nothing downstream checks
anything: without the guard, `--name` at the end of argv silently binds the empty string — the
exact shape of the bug that killed `tasks` at startup. Four tests now cover it, and removing the
guard fails all four.

Worth recording separately: the first break-test attempt reported zero failures because the
injection itself had not applied. An unverified break-test proves nothing. The second asserted
the marker was present before replacing it.

## 2026-08-09 — `hash`: the empty category, filled

Phase 1 of [the standard library](stdlib.md). Crypto/hashing was the one category machteld had
**entirely** empty while Python, Go and Deno all ship it: Tcl 9 offers CRC32 and Adler32 through
zlib and nothing else, so there was no way to ask whether two files were the same, and no source
of unguessable bytes at all.

`hash sum / file / hmac / start / update / final / list / algorithms / random`, over Windows CNG.
Nothing vendored and no OpenSSL — the provider ships with the OS, so the ecosystem policy's
question, "can I own this snapshot?", does not arise. Checked against the published NIST and
RFC 2202/4231 vectors and against `Get-FileHash`; 25 MB streams in about 30 ms in 64 KB chunks.

Shaped to the architecture rather than to another language's API: algorithms are **values, not
subcommands**, so adding SHA-3 later cannot widen the subcommand surface; an incremental context
is stateful and therefore a **token** with the `child#N` / `pty#N` / `watch#N` lifetime, and
`final` consumes it; `hash file` opens through the Tcl channel layer, so zipfs paths work and a
digest never depends on line endings.

### The bug worth recording

**Which bytes get hashed** is the whole correctness question, and the first implementation got it
wrong in a way that only showed up on non-ASCII input.

Tcl 9 carries **two byte-array object types and registers only one of them** under the name
`bytearray`, so comparing `v->typePtr` against `Tcl_GetObjType("bytearray")` returns false for
precisely the values `binary decode` produces. Those fell through to the string path, where each
byte was read as a character and re-encoded: `binary decode hex 636166c3a9` hashed as *seven*
bytes of UTF-8 rather than five bytes of data. Silently, and with a plausible-looking digest.

It cost some time because the symptom pointed the wrong way — the string path looked broken when
it was correct, since the "expected" values were being computed through the same broken path.
What settled it was instrumenting the C to report the bytes it was about to hash, and then
checking against an external oracle (`Get-FileHash`) rather than against machteld itself. A hash
that agrees only with itself is worthless.

`Tcl_GetBytesFromObj` is not the fix either: it is a coercion, not a predicate, and will happily
turn the string `café` into four Latin-1 bytes. The type **name** is the one thing that is both
public and true. The regression is gated — restoring the pointer comparison fails three checks.

## 2026-08-09 — Phase 0: the prelude becomes a first-class citizen

Groundwork for [the standard library](stdlib.md), and deliberately done first: everything in that
plan which is not C lands in the prelude, and the prelude was the part of machteld that did not
hold itself to machteld's own contract.

- **Every prelude error now carries a code.** Eleven bare `return -code error` in `wrap` and
  `help` put them outside the error registry entirely — nothing to document and nothing a scan
  could find. They raise through **`Fail domain code msg`** now, the prelude's mirror of the C's
  `mt_error`. `WRAP` and `HELP` join the domain table; `timeout` and `unsupported` join the code
  registry. A shared helper is told which domain to raise in (`_dur2ms PTY $v`), for the same
  reason the C option parser is: the domain is the verb you called, never the helper that failed.
- **The manifest describes Tcl verbs as fully as C ones.** It used to stop at `kind tcl` plus
  `info args`. It now reads **`info body`** — the actual body of the actual command, so it cannot
  drift and it works inside a wrapped tool — for domain, codes and options, following a helper
  one level to attribute what it raises to its caller.
- **A Tcl subcommand behind a C verb is no longer second-class.** `pty expect` is written in the
  prelude, and the manifest was silent about both its `-timeout` and the `timeout` it raises.
  `pty` declares both now.

Why the timing mattered: adding four or five Tcl verbs on top of the old state would have made
the uncoded error the *norm* rather than the exception, and left creed 4 covering barely half the
palette — decaying in exact proportion to how much standard library got added.

Both new gates were broken on purpose. Injecting one uncoded `return -code error` fails the
suite; neutering the derivation fails nine checks. The second break also showed the checks
aborting the run partway through, so they were made to survive a missing key and report the whole
picture instead of the first four.

## 2026-08-09 — a cockpit, built and removed; and the rules that changed because of it

The question was whether to ship GUI tools inside `machteld.exe`. Three positions were argued
and nine adversarial critics attacked them; every affirmative case died, mostly on dispatch
mechanics. The framing was wrong. **machteld already ships Tcl — the prelude — and a third of the
palette is already written in it** (`help`, `manifest`, `scope`, `version`, `vtstrip`, `wrap`).
The argument had been about packaging *programs* when the question was about shipping *code*.

And the tool worth shipping was neither of the ones being argued over. `manifest` says what
machteld can do; nothing said what it is *doing*.

- **`mt`** — a live window over the current session. **Built, measured, and removed the same
  day.** It refreshed 8×/second idle and **0** times while blocked in `child wait` (2039 ms) or
  `watch read` (1504 ms) — the calls supervision is made of — and while frozen it showed stale
  rows with no indication, the same defect fixed in `tasks` hours earlier. It was shelved first
  with the defect documented; that was wrong, because "shelved with a known defect" is how a
  drift of half-built things starts. Removed. In the history at `98bc96e`.
- **`watch info` and `pty info`** — **kept.** `child` had `info`; the other two handle verbs
  returned bare tokens, so a watch could not be attributed to a directory. They report queue
  depth and pending bytes where a read would have emptied them, which is the right primitive with
  or without a window on top.

- **Rules 5 and 7 rewritten**, which is the lasting outcome. Rule 5 required a tool to demand a
  capability before it could be built; that stifles the exploring which is how a verb's shape
  gets found, and it was softened once and bit again. Building on spec is now allowed. Rule 7
  used to freeze a shape on ship — machinery for a promise `0.x` says is not being made — and now
  says the opposite: **nothing is frozen before 1.0.0, and what binds is finishing what you
  start.** A verb is finished or it is out. `mt` was the first thing the new rule touched and it
  was not exempted from it.

### Why it is a verb and not an exe — architecture, not preference

`proc_ctx` is allocated **per interpreter** and passed to every command as its client data.
There is no global registry, no shared section, no file. A separate `monitor.exe` would
enumerate its *own* children, which is nothing, and could not see another machteld's tokens at
all. The tool has to run inside the session it reports on. That settled a question that had been
framed as taste: this one tool ships as Tcl because it cannot ship as anything else.

### Non-destructive by construction

The sharper constraint, and the reason `watch info` / `pty info` exist. `watch read` **drains**
the event queue; `pty read` **consumes** the child's output. A monitor built on either would
steal from the program it is monitoring — an observer that changes what it observes is worse than
no observer. `mt` calls neither, and the suite proves it: six snapshots leave `pending` at 2 and
16, and the owner can still read every event afterwards.

The **Detached** section is the one that earns its place. `detach` is fire-and-forget on purpose
and tracks nothing, so those processes are invisible to `child list` by design; `mt` finds them
through `ps` by parent pid. The distinction drawn is between what machteld *controls* and what
it is merely *responsible for*, and a monitor that quietly omitted them would be flattering
itself.

### Gates repaired, and one break-tested

- The **registry scan** read four hardcoded `.c` files and nothing else. It now globs `src/*.c`
  — so a new source is inside the gate on arrival rather than when someone remembers — **and**
  reads the prelude, because `mt` raises `{MACHTELD MT badvalue}` and creed 5 does not say "the
  errors written in C". One hole is left open and named in [the contract](contract.md) rather
  than hidden: `wrap` and `help` still raise 11 bare `return -code error` with no code at all.
  The suite prints that count every run.
- The **pty ensemble map** in the prelude is hand-maintained, and `pty info` existed in the
  binary while being uncallable because the map still had five entries. The count stayed at six
  either way — five core plus `expect` — so only a set comparison finds it. Break-tested: with
  the entry removed the manifest reports seven subcommands and the binary six, and the gate
  fails on its own.
- **The window tests were files nobody ran.** `tasks_ui.tcl` and now `mt_ui.tcl` are driven from
  the suite by glob, so a new `*_ui.tcl` is picked up without being remembered — the same fix as
  the tool selftests, for the same reason.

Measured: `mt.tcl` costs **1.3 ms** to parse at startup, and Tk stays unloaded until the window
is opened, so a machteld that never calls `mt` pays nothing for it.

## 2026-08-09 — `ps` and `tasks`: seeing processes we did not start

A task manager was asked for. Writing it named the gap immediately: machteld could **supervise**
processes it launched — born-in-job, tree-kill, caps — and could not **see** one it had not.
`child list` returns machteld's own tokens; there was no `CreateToolhelp32Snapshot`, no
`EnumProcesses`, nothing machine-wide anywhere in `src/`. So `ps` was built to fit the tool,
which is rule 5 running the right way round. (That rule was rewritten later the
same day — building on spec is now allowed — but this is still how `ps` arrived, and still the
version that produces the best-shaped dict.)

- **`ps`** ([the palette](palette.md)) — `list` / `info` / `kill ?-tree?`. A row carries
  `pid ppid name exe mem private cpu threads started access`. 257 processes in 11 ms; the
  numbers agree with `Get-Process` (63.937 s of CPU against its 63.97).
- **`cpu` is cumulative, not a percentage.** A rate needs two samples and a clock, so computing
  one inside the verb would mean hidden state and an answer that depended on when you last
  asked. The tool divides; the verb reports. Same reasoning as `watch`'s per-read coalescing.
- **Denied is not zero.** Without elevation about 150 of 257 processes refuse inspection. They
  stay in the listing — with their snapshot fields, `access 0`, and every unreadable field the
  **empty string**, never `0`. Failing the whole listing over a process you may not inspect
  would make the verb useless on exactly the machines it is for.
- **`tasks`** (`tool/tasks`, wrapped to `tasks.exe`, 6.1 MB) — flat sortable list, filter, live
  refresh, End Task and End Tree. Deliberately smaller than Windows' own: no grouping, no
  graphs, no services tab. Rows reconcile rather than rebuild, so a selection survives a refresh
  — which matters because the next button is End Task.

### Three gates were passing vacuously

Worth recording, because all three were *green* while the thing they check was absent.

- The **error-code registry** scan knew `mt_error(interp, DOMAIN, code)` and literal
  `Tcl_SetErrorCode`. `ps.c` names its domain once inside its own raiser and passes only the
  code — so the scan found nothing in it, and all four closure checks passed on an empty set.
  The manifest cross-check is what actually caught `PS` and `denied` going undocumented.
- The **palette-doc** check matched `*$v*`. A two-letter verb passes that on the strength of
  "steps", "helps" or "maps". Tightened to a whole-word match, it immediately found that
  `vtstrip` and `version` had never been documented either — `vtstrip` appeared only inside a
  comment, `version` only as the unrelated `store version`.
- The **manifest generator** attributed `-tree` to `info`, because `kill` was an implicit
  fallthrough with no `idx ==` marker for the branch scanner to see. Same failure as `watch
  read` last release.

A gate that can be silently emptied is worse than no gate. Each was repaired at the scanner
rather than at the symptom, and the registry gate was then broken on purpose to confirm it bites.

### And one real bug, found only by driving the window

`TerminateProcess` on a process that has **already exited** fails with `ERROR_ACCESS_DENIED` —
the same error a genuinely protected process gives. Read at face value, `ps kill` told the user
to re-run as administrator about a process that had simply finished, which in a task manager is
the likeliest case of all: you click End Task on the row that was already on its way out.
`ps_kill_one` now consults the exit code before reporting, and answers `notfound`.

The model selftest could not have found this; `test/tasks_ui.tcl` drives the real mapped window
— selection, sorting, reconciliation, and End Task through the button's own callback — and did.

## 2026-08-08 — 0.3.0: the palette describes itself, watches files, and reaches a tool

The release rule was ratified before the work: **0.3.0 ships when a tool ships**, because a
toolkit earns its palette by reaching one. `changes` is that tool.

- **`manifest`** ([the contract](contract.md)) — one dict, no arguments, navigated with
  `dict get`, so no subcommand vocabulary is invented and none has to be frozen. Nothing in it
  is hand-maintained: the C half is derived from `src/*.c` at build time by
  `tools/genmanifest.tcl`, the Tcl half is read out of the live interpreter. It describes
  itself, and a wrapped tool carries it.
- **`watch`** ([the palette](palette.md)) — live directory events over `ReadDirectoryChangesW`.
  Handle plus blocking read, mirroring `child start` / `wait`, so the palette keeps one lifetime
  model and needs no event loop. Coalesced per read (no hidden timer, so the same reads give the
  same answer), `-raw` for the unmerged stream, and lost events reported in-band rather than
  silently dropped.
- **`wait` became the one multiplexer.** It was child-typed throughout; it now resolves any
  token through a small seam, so `wait -any $child $watch` blocks on both and names the winner
  with no polling. What "ready" means stays the handle kind's business.
- **`changes`** (`tool/changes`) — the first real tool: what is changing in a tree on the left,
  the contents of the one you click on the right. Pure Tcl/Tk, stamped by `wrap` into its own
  6.1 MB exe, and built by the build so `wrap` is proven against the artefact being released.

**Errors became a contract rather than a promise.** The domain is now the verb you called —
`pty` raises `MACHTELD PTY`, not `MACHTELD RUN` — and the codes are a closed registry in
[the contract](contract.md) that a test holds to the C in both directions. Two defects fell out
of writing it down: an unresolvable program answered `launch` from `run`/`child`/`pty` and
`notfound` from `detach` (same condition, two codes, and the docs published the wrong one), and
`store` set no error code at all. Both fixed; `nohandle` now names the genuinely different
failure that used to share `notfound`.

Also: Tcl/Tk pinned at **9.0.4**; the name **machteld** ratified, no longer provisional; the
surface frozen and additive-only, with the one hole in that promise (prefix-matched subcommands)
recorded in [direction](direction.md) rather than papered over. The rules this stretch runs by
are in [direction](direction.md).

## 2026-07-09 — Built: M0–M2 + the tool factory

The design became code. Landed since the initial bundle:

- **M0** the console starpack host; **M1** the execution core (`run` / `child` / `wait` / `scope` / `detach`) over winjob, with the adversarial invariants (born-in-job, tree-kill, die-with-parent, CVE-2024-24576, quoting) verified; **M2** the ConPTY `pty` + `expect` + `vtstrip`, verified on real hardware.
- `run` polish: `-stdin`, `-env`, `-onout` / `-onerr` streaming, exe-resolution hardening.
- `store` (statically-linked SQLite).
- The **tool factory**: the shared `Machteld_RegisterLibs` AppInit, the GUI `WinMain` bare (the proper no-console host — not a PE byte-flip), both bares embedded in `machteld.exe`, and the self-contained [`wrap`](palette.md) verb.

Docs reconciled with the code: [index](index.md), [overview](overview.md), [architecture](architecture.md), [packaging](packaging.md) (new), [palette](palette.md) (built vs deferred), [roadmap](roadmap.md).

## 2026-07-07 — Initial design

Full architecture and v1 scope specified in one design session and captured as this bundle:
identity and posture, the [creed](creed.md), the everything-is-a-dict [contract](contract.md),
the linear [execution model](execution-model.md) with bounded handle lifetime, the surface
conventions and the hybrid [palette](palette.md), the vendor-and-freeze [ecosystem policy](ecosystem-policy.md),
and [milestones](roadmap.md). Working name: machteld (provisional). No code yet.
