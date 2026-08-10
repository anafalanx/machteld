---
type: log
title: Change log
description: Update history for the machteld knowledge bundle and build.
tags: [machteld, log]
timestamp: 2026-07-09
---

# Log

## 2026-08-10 — the factory is retired: 10.2 MB → 6.0 MB, and the tools ride inside

Step 3 of [the front-door plan](front-door.md). `wrap`, both embedded bare hosts, the GUI
`WinMain` host, `tools/pack.tcl` and the tool-stamping loop at the end of the build are gone. The
build used to finish by running the exe it had just produced five times, turning five tool
directories into five 5.9 MB standalone exes; it finishes when the exe is built now.

**The five tools ride inside `mt.exe`** at `//zipfs:/app/tool/<name>/main.tcl`, and resolution
gained a tier: **builtin verb → shipped tool → curated tool**. `mt sums .` sources the script in
this process — no exe on disk, no manifest entry, no process to start. None of the five names
collides with any of the 273 the workspace curates.

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
