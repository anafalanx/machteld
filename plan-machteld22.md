---
type: plan
title: machteld 22
status: DRAFT, 2026-10-30. zef's plan for zef 22 (plan-zef22.md on zef's
  zef-22 branch, f741ffe), revised for a runtime-only machteld 22 after the
  owner's rulings of 2026-10-29. Section 6 holds the re-cut decisions D1-D8
  and the topics under research: FFI, the Thread package and Tcl packages.
relates: README.md, BUILDING.md, commentary.md, docs/roadmap.md,
  docs/direction.md, docs/creed.md, tools/stabilization.json
---

# machteld 22

## 0. How to read this

Five kinds of statement appear here:

- **Rulings**: what the owner decided (section 1) and the rulings in force
  before (section 3). They are constraints, not reopened.
- **Proposals**: the plan's substance, each grounded in what was read or
  measured, with its date.
- **Decisions D1-D8** (section 6.1): questions for the owner, each with its
  options and a recommendation. The recommendation is not the ruling.
- **Under research** (section 6.2): FFI, the Thread package and Tcl packages.
  Their decisions follow.
- **The log** (section 7): a dated line per commit on `machteld-22`, with its
  gate result.

The mapping pass of 2026-10-28 (per-file port maps, the bug ledger, feature
designs and a critic's review) is kept outside every repository, in
`C:\dev\.preserve\2026-10-28-zef22-mapping.json`; read it with
`dist\0.21\machteld.exe C:\dev\.preserve\2026-10-28-zef22-mapping-digest.tcl
FILE bugs` (or `ports`, `features`, `critic`, or `area tools`, `tcl`,
`native`, `docs`). It was written for porting into zef's renamed `core\`, so
its paths and names are zef's; its account of what each change does, of each
finding and of how each PowerShell tool translates to Tcl holds here, with
machteld's names and without `core\`.

## 1. The owner's rulings (2026-10-29)

> We go back to just building machteld. On the machines it is used on, dev
> environments will be built; those probably will get a local-only repo and
> be simply backed-up.

1. **The name.** The system's name goes back from zef to machteld. The next
   release is machteld 22, one natural number, and only a change to the
   runtime makes a new number (c9cbff2).
2. **The repository holds the runtime only:** `machteld.exe`, Tcl/Tk 9 with a
   native C core in one executable, its source at the repository root. What
   is built with it, the owner's development environments (formerly the zef
   system: its verbs, editor, run, backup, pins and settings), is not
   machteld's business. Those get local-only repositories on the machines that
   use them, and nothing of them comes into this one. machteld still caters
   for development tools first, so its documentation says what it is good at.
3. **The wording** (735b738). The product sentence, which is also
   direction.md's decision filter: "machteld is a compact Windows runtime for
   Tcl/Tk 9 programs. It is strongest at what tools do: supervised processes
   and terminals, files, HTTP, JSON, hashing and SQLite, in one executable that
   installs nothing." The first admission question follows from it: "Does this
   strengthen what machteld is strongest at, for many programs, beyond what
   they can do in Tcl?" The interactive banner says "compact Windows runtime
   for Tcl/Tk 9", and the executable's file description "machteld runtime".

The goal of zef's plan carries over to the runtime. The owner, 2026-10-28:
"Let's fix everything we can, diligently, and go for a high quality zef 22
release."

## 2. Where things stand (2026-10-30)

1. **This repository** is `C:\dev\machteld`, a clone of `C:\dev\_machteld`,
   on the branch `machteld-22`. `main` stays at bc6a4a3: the 0.21 release
   (8ad9507) and its three later commits, 7a15542 (wrap's reference opt-in),
   bfe307d (help and pool fixes) and bc6a4a3 (build provenance). 8bcc1ec
   commits the 0.22 candidate as it was left on 2026-10-02: the stabilization
   of 2026-09-30 to 10-02, whose record, `tools\stabilization.json`, lists 44
   findings, 18 of them confirmed defects fixed and verified, and whose step
   12, the release gate, had begun. The consolidation since (section 7)
   carried zef's Tcl build to the repository root and the candidate's own
   tooling into it, so that the build and its tests are Tcl only; moved the
   version to 22 and the wording to the owner's; and brought in from zef what
   is the runtime's own: the agents' commentary, the els method, BUILDING.md
   and this plan. On the way it fixed a test race the gate met (B16).
2. **machteld 22 builds and passes its gate on the build PC**, every commit
   of the consolidation included: from PowerShell, `dist\0.21\machteld.exe
   tools\gate.tcl --msys C:\dev\.z\r\msys2` builds `out\machteld.exe` with
   `-Werror` and runs every group on it (the run that passed 4e0a6db: 58
   steps after the release build, 2,141 ok checks and none failed, 1,326 s).
   `detach` only ever takes its denial branch there (R16).
3. **The build PC has everything the build needs** (BUILDING.md): the signed
   0.21 as the build runtime (`dist\0.21\machteld.exe`, SHA-256 1027eef1...,
   signed by Open Source Developer Vincent Vercauteren); MSYS2 at
   `C:\dev\.z\r\msys2`, matching the five tool hashes of the lock, which the
   bootstrap checks whenever the gate builds; the four pinned source archives
   in `.cache\deps\downloads`, so no download is needed; signtool 10.0.26100
   and the Certum certificate, valid until 2027-07-03; Windows 11 Pro, build
   26200.
4. **The runtime has real bugs** (section 4.2). The mapping pass found them
   on 2026-10-28 in zef's core (the 0.21 with the console-control proposal,
   renamed) and checked each against the candidate, which fixed about a
   third: `scope` breaks `break`, `continue` and `return` (R1); `run -stdin`
   fails when the child stops reading (R5); no job the runtime makes allows
   breakaway, so `detach` never works under a machteld parent (R16), and the
   commentary's claim of 2026-10-28 that the runtime's jobs allow it is wrong
   (its entry of 2026-10-30 says so); `detach` keeps the host's console and
   process group (R8); a captured child of a host without a console gets a
   console window of its own (nothing in `src` passes `CREATE_NO_WINDOW`);
   and a crashing child may wait in Windows Error Reporting (inferred: `src`
   sets no error mode, and its jobs lack
   `JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION`).
5. **The els method is in the runtime's corpus.** z's working tree replaced
   its copy (`C:\dev\.z\the-els-method.md`, uncommitted since 2026-09-08) with
   a pointer: the method lives in machteld, as
   `C:\dev\_machteld\docs\els-method.md` and the guide
   `machteld/guide/els-method`. The newest text (z df38fae, 2026-09-25) is that
   guide now, `docs\els-method.md` on this branch; the pointer's path holds
   once `_machteld` has this branch.

## 3. Rulings in force

1. **The version** (c9cbff2): one natural number. Programs ask for `package
   require machteld 22-`; a program that must be read again before it runs on
   a newer runtime names an upper bound, which Tcl excludes (`22-24`). The
   build tools keep running on the signed 0.21 until a signed 22 exists.
2. **The creed and the direction** (`docs\creed.md`, `docs\direction.md`):
   Tcl/Tk, with C and C++ the only native languages. The tooling is Tcl too:
   no PowerShell, C#, Go, TypeScript or shell script remains, and bash runs
   only inside MSYS2, for Tcl/Tk's configure and make (since 306b38f).
3. **The candidate's constraints** (`tools\stabilization.json`): the
   repository stays private; released artifacts and wrap's documentation
   opt-in are preserved; Tcl/Tk and native C/C++ only, with no engines, Lua or
   kuu integration; steps 4 to 7 change the retry defaults and add transport
   limits while keeping the public palette. So `pool` and `pmap` make one
   attempt by default, with retries an explicit opt-in for replay-safe work;
   frames, items, batches and results are bounded, and a `run -onout` or
   `-onerr` line is limited to 16 MiB; JSON has a strict UTF-8 boundary, and
   `test\json_test.tcl` pins every implementation-defined JSONTestSuite case
   by name (its J1 table).
4. **The owner's choices for the candidate's step 12**
   (`tools\stabilization.json`): a brief GUI acceptance session is allowed,
   closing every window and process it owns afterwards; signing is deferred
   until the unsigned build is prepared and tested; publication is not
   authorized, and the signed 0.21 is preserved. The ruling of 2026-10-29
   replaced the candidate's chosen version with 22.
5. **Two machines** (zef's BUILDING.md of 2026-10-28, which called the build
   PC "the owner's other machine"; BUILDING.md here): `machteld.exe` is built
   and signed on the build PC, where unsigned builds run only for building and
   testing; other machines run signed releases only. Signing is the owner's
   step.

## 4. What machteld 22 is (proposal)

machteld 22 is a runtime release: the candidate's stabilization, the build in
Tcl and the ledger's remaining fixes, in one signed `machteld.exe`.

### 4.1. What it contains

- **The candidate (8bcc1ec).** Native: every confirmed-defect fix and
  hardening in `dirs.c`, `hash.c`, `http.c`, `json.c`, `proc.c`, `publish.c`,
  `store.c` and `winjob_cmdline.c` (interpreter-owned process cleanup,
  channel identity, reentrant close, strict JSON UTF-8, typed depth, store
  result ownership, NUL paths, the hash counter, capacity bounds, the 16 MiB
  callback line), with their tests and undefined-behavior-trapped boundary
  drivers. Tcl: the help truncation fix (bfe307d); the worker protocol, pool
  and pmap limits and their one-attempt default; pool close during wait; the
  strict JSON table. wrap: the reference corpus only with `--with-docs`
  (7a15542), explicit inventories (`--manifest`, `--plan`) and application
  identity (metadata and icons, `src\resource.c`; D1). The documentation's
  corrections of documented behavior (the stabilization's step 11).
- **The consolidation.** The release build, bootstrap, reference generator,
  gate, development loop, native analysis and every driver test in Tcl
  (b0c4edc, 306b38f, 2be5c9e, 75a600b), with the candidate's hardening
  carried in: the bootstrap refuses steering variables, runs bash without
  profiles and records the effective toolchain's fingerprint (d29c268); the
  test groups run in a clean lane environment (c64ec38); the release build
  publishes in one operation (2a39777). Version 22 and the owner's wording
  (c9cbff2, 735b738). The console-control proposal, as documentation only
  (c8e1173). The els method as a guide, the streaming-bounds test's race
  fixed, the commentary, BUILDING.md and this plan (section 7).
- **Not carried from zef:** its rename (840fbc2) and everything of the
  environment (`zef.tcl`, `verbs\`, `lib\`, pins, settings, the Go ignition,
  the TypeScript, `DESIGN.md`), with zef's phases and decisions for its
  editor, the agents' homes, backup, the work PC, its verbs and its namespace.
- **Not ported from the candidate:** the reference stage cache, with its
  PowerShell and C# serializers (D5).

### 4.2. The bug ledger

The mapping pass of 2026-10-28 (`result.bugs` in the mapping) checked every
item against zef's core and against the candidate. The consolidation
re-checked R16 on 2026-10-30; the other items stand as mapped until each is
fixed or checked again. Each new fix lands with a regression test that fails
before it.

| Fixed in the candidate (8bcc1ec), carried | R2 help, R3 json NUL, R4 typed null, R10 key leaks, R18 interp cleanup, S2 pool stderr eof; json bytearray as Latin-1; typed depth; recycled channel names; reentrant child close; pool close in callback; store leaks; NUL paths; hash counter |
|---|---|
| New fixes in 22 | R1 scope -level; R5 -stdin broken pipe; R6 kill after exit; R7 canon on a locked file; R8 detach console and process group; R11 capture race; R12 strict text from -onout and store keys; R13 -env block size; R14 pty_free; R15 dead code; R16 breakaway (merged with the limits write); R17 one size grammar; R19 comments; R22 PATH from -env; R24 cli parse name; R25 bytearray docs; S3 watch overflow; S4 worker non-error codes; S7 creed wording (its rewording done in c9cbff2); -onout read errors; long resolved paths; crash containment (no error dialogs from children) |
| Deferred to 23 | R9 the polling monitor (a completion-port supervisor is a redesign; the `-onout` pump polls the same way, `src\proc.c:1243`, and read 16 MiB in 3 to 11 s on the build PC); R20 limit status; S1 incremental UTF-8 for pty; S5 GUI fatal message; S6 bounded reap; R21 rename pairing across reads; R23 narrowing the global path |
| Build, done | B12 BUILDING.md's interpreters (BUILDING.md); B13 toolchain fingerprint (d29c268); B16 the streaming-bounds overflow check raced its fixture's descendant, whose newline split the overflowing line when the pump was slow (found and fixed in f6393df) |
| Build, partly | B3 retried renames (the development cache's publications in 306b38f, the release build's in 2a39777; `tools\reference.tcl`, `tools\package.tcl` and `tcl\docs.tcl` still rename once); B4 bash profiles (d29c268; the bash steps have no timeout yet); B7 publish semantics (2a39777: one operation, and debris checked; not write-through, retried on any error) |
| Build, open | B1 detach coverage (with R16); B2 tolerant cleanup; B5 curl timeouts and tar checks; B6 MSYS2 discovery (BUILDING.md names `--msys` and `MSYS2_ROOT`; `tools\dev.tcl` takes no `--msys`); B8 attribute checks; B9 cache-path match; B10 a development build must not overwrite a signed exe (D4); B11 publish only after every lane passed (D3); B14 a signing recipe (at release, BUILDING.md); B15 the entry test runs `whoami.exe` by bare name (`test\entry_test.tcl:145`), so a caller's PATH with Git's tools first gives its ACL fixture no SID (found in c9cbff2's first gate run, from Git Bash) |

### 4.3. What development tools asked of the runtime

zef's verbs asked for these (zef's plan, its section 4.3; the commentary's
entries of 2026-10-28). machteld builds no development environment, so none
is admitted for that reason: each is now judged by direction.md's first
admission question, whether it strengthens what machteld is strongest at, for
many programs, beyond what they can do in Tcl (D2).

1. **Hidden-desktop launches:** `run`, `child start` and `pty spawn` on a
   desktop of the host's own, so that what a tool starts never takes the
   user's keyboard focus.
2. **Console-less launches:** captured children without a console window of
   their own, so a host without a console (a `wrap --gui` tool) opens none per
   child; `detach` without the host's console, in a process group of its own
   (the defect half is R8).
3. **Console control:** `console ctrl default|catch` and `console
   interrupts`, so a host decides what Ctrl-C means
   (`docs\proposals\console-ctrl`).
4. **Detach from jobs:** `detach -breakaway required|preferred`, where
   `preferred` starts the program inside an enclosing job that forbids
   breakaway (the defect half, the runtime's own jobs, is R16).
5. **A lock:** `lock take path ?-timeout d?` and `lock release`, a
   `LockFileEx` lock that Windows releases when its holder ends; Tcl can only
   create a file exclusively, which a crashed holder leaves behind.
6. **Publish:** the atomic replacement behind `wrap` and the release build,
   `::machteld::Publish`, as a documented command, perhaps with `-wait`.
7. **dirs with file rows:** files too, each with its kind, size, modification
   time in 100-ns units and attribute word, from the one enumeration `dirs`
   already does: what a backup, a sync or "what changed since" needs. The
   attribute word would also bring back B8's checks.
8. **A shortcut:** `shortcut write|read`, through `IShellLink`.

Smaller wishes from the same work: an exact environment for children
(`-clearenv`), `http get -to FILE`, `-encoding` on capture, `canon`
attributes and times, `-priority` and `-stderr stdout`. `cli parse` naming
the program is a fix (R24).

## 5. Phases

0. **Preserve** - done: the candidate's read-only snapshot,
   `C:\dev\.preserve\2026-10-28-machteld-0.22-candidate` (verified when made);
   the candidate committed as left (8bcc1ec); zef's `zef-22` branch,
   `C:\dev\.preserve\2026-10-29-zef-22-branch`.
1. **Baseline** - done: 8bcc1ec.
2. **Consolidate** - done (section 7): the build in Tcl, the candidate's
   tooling carried into it, version 22, the owner's wording, and the
   runtime's own knowledge from zef. Every commit gated green.
3. **Fix the remaining ledger** (4.2), test first: each fix with a
   regression test that fails before it; grouped by severity; each group gated
   green and committed, then reviewed adversarially.
4. **Runtime features**, only those the owner admits (D2), each designed
   once: native or Tcl by direction.md's placement questions, a manifest
   entry, a reference page, tests.
5. **Release**, on the build PC: the roadmap's release gate, the candidate's
   step 12. Freeze 22; gate from a fresh clone and a fresh dependency cache;
   compare the clean build with the matching incremental one; the owner signs
   a copy at a release path, never `out\machteld.exe` (BUILDING.md); the gate
   on the signed bytes (`--skip-build --runtime FILE`); the acceptance that
   needs the owner (D7); release notes, with the signed file's SHA-256;
   publication on the owner's word (D8).
6. **After the release:** the build tools move from the signed 0.21 to the
   signed 22 (`package require machteld 22-`), in a commit of their own,
   gated on the signed 22.

zef's phases for its verbs (its phase 5), zef on the build PC (7), the work
PC's swap (8) and its projects standing alone (9) are the environment's, and
are dropped.

## 6. Decisions

This section is the consolidation's re-cut of zef's decisions. The owner has
ruled on several of them (application identity, features in 22, the ledger,
the owner's acceptance, publishing) and on the topics of 6.2 (Thread on
2026-10-29, the others in a poll of 2026-10-30); those rulings, with their
reasons, take this section's place when the plan is next revised.

### 6.1. For the owner

These re-cut zef's D1-D15 to the questions that still concern the runtime,
numbered afresh, and add what the consolidation left open. Re-cut: zef's
scope (D3) becomes D1 and D2, and one API per feature (D7) waits for a
feature to be admitted; the gate (D9) becomes D3; the release ledger (D12)
D6; the owner's acceptance (D13) D7; the signed runtime's way to the work PC
(D15) D8, publishing the release. Settled: the two machines (D1) are section
3.5; the candidate is committed (D2b, 8bcc1ec); wrap's reference opt-in (D4)
is in since 7a15542; the version checks (D10) keep the candidate's markers,
extended to natural numbers (c9cbff2); the development loop (D11) decides by
content (306b38f), and where it publishes is D4. Dropped as the
environment's: a plain copy of `C:\dev` (D2a), the front door for zef's verbs
(D5), zef's own namespace (D6), the runtime range in `zef.tcl` (D8) and zef
on the build PC (D14). New: D5, the reference stage cache that 6799d2b left
open.

**D1 - Application identity in 22.** The candidate added wrap's application
metadata and icons: `src\resource.c` validates an ICO file and the host's PE
resources and stamps them before the payload is appended. zef's plan left it
out of zef 22 (its D3), because it parses untrusted bytes and had never run
under undefined-behavior traps. Since 75a600b its primitives run under those
traps in every gate (71 native checks, malformed, oversized and overlapping
icons and refused hosts among them), beside the application identity test's
65 checks. (a) Keep it in 22, as the candidate has it. (b) Move it to 23: one
commit removes it from `machteld-22`, a branch keeps it, and 23 reverts the
removal. *Rec: (a). It is built, documented and gated, its inputs are the
user's own files inside the trusted-local-code boundary, and a removal is a
change of its own to test. (b) is the smaller release.*

**D2 - Runtime features in 22** (4.3). (a) None: the list becomes the
candidates for 23 and later, each still to pass the admission question; the
ledger's fixes stay in 22 even where they touch the same code (R8, R16). (b)
Only what the ledger's fixes nearly are: `detach -console new` beside R8, and
`detach -breakaway preferred` beside R16. (c) zef's must list, 4.3's eight.
*Rec: (a). 22 is the stabilization's release and its release gate is not
done; each feature needs a design, a manifest entry, a page, tests and
acceptance; and the needs came from one environment's verbs, not yet from
many programs.*

**D3 - The gate's default and its publication** (c64ec38 left the default
open; B11). (a) As now: without `--group` the gate is the release, the build
and every group, and it publishes `out\machteld.exe` before the first lane.
(b) As (a), but the build goes to a candidate the run owns, published as
`out\machteld.exe` only after every lane passed. (c) The candidate's default:
without `--group`, the fast group and no build; the release only with `--group
release`. *Rec: (b). BUILDING.md stays true, and a failing run can no longer
leave an untested build where the development loop and the docs expect the
runtime.*

**D4 - Where development builds land** (B10). (a) As now: the development
loop and the gate both publish `out\machteld.exe`. (b) The development loop
publishes `out\dev\machteld.exe`, and only the gate writes `out\machteld.exe`.
(c) As (b), and every publication refuses to replace a file that carries an
Authenticode signature. *Rec: (b). Signing happens on a copy at a release
path (BUILDING.md), so (c)'s guard would protect only against a mistake in
that recipe.*

**D5 - The reference stage cache** (6799d2b). The candidate cached the
reference conversion's stages with PowerShell and C# serializers; they were
not ported. (a) Leave it out: unchanged builds reuse a reference generation by
content, and a documentation edit generates the reference again, in about a
minute. (b) Port it to Tcl. *Rec: (a).*

**D6 - The release ledger** (zef's D12). (a) This plan's section 7: a dated
line per commit, with its gate result; `tools\stabilization.json` stays the
candidate's record. (b) A record for 22 in the form of stabilization.json.
*Rec: (a).*

**D7 - Acceptance that needs the owner** (zef's D13): `--public-tls` (it
contacts public hosts), `--interactive-pty`, the detach success path (from a
shell outside any job that forbids breakaway), `--interactive-gui`, and any
test that opens a window beyond the wrap lane's brief one. No gate run
reaches the detach success path today: the gate runs its lanes inside its
own jobs, which forbid breakaway (R16). (a) All at release, each on the
owner's word. (b) Each as soon as the code it checks changes, on the owner's
word. *Rec: (a), with (b) for a change to detach or the console.*

**D8 - Publishing the signed release** (zef's D15, re-cut for the runtime).
(a) A release of the GitHub repository anafalanx/machteld, as 0.21 was (its
tag v0.21; `dist\0.21` keeps that release's executable, release notes and
`SHA256SUMS.txt`), on the owner's word. (b) No published release: the owner
keeps the signed file and copies it to the machines that use it. *Rec:
(a).*

### 6.2. Under research (decisions to follow)

FFI, the Thread package and Tcl packages beyond Tcl/Tk's own were studied on
2026-10-29: `C:\dev\.preserve\2026-10-29-ffi-thread-packages-research.json`,
and for Thread also `C:\dev\.preserve\2026-10-29-thread-studies-journal.jsonl`.
Their decisions, with the studies' reasons, follow in this plan. Nothing of
them is in `machteld-22`.

- **FFI:** calls from Tcl into Windows' DLLs and a program's own, through a
  foreign function interface in the runtime.
- **The Thread package:** Tcl's Thread extension inside `machteld.exe`.
- **Tcl packages:** which packages beyond Tcl/Tk's own the executable
  carries, and how its interpreters find the others.

## 7. Log

<!-- machteld-version-history: begin -->

- 2026-10-28 · the candidate's post-0.21 work snapshotted read-only to
  `C:\dev\.preserve\2026-10-28-machteld-0.22-candidate` (verified).
- 2026-10-28 · zef 338e534 · zef copied the els method (z df38fae) to
  `notes\els-method.md` on its zef-22 branch.
- 2026-10-29 · 8bcc1ec · the 0.22 candidate committed as left on 2026-10-02:
  the baseline.
- 2026-10-29 · b0c4edc · the reference generator, bootstrap, release build,
  tests and gate in Tcl (zef f43b93b, 2ee6832, f7b2260, at the root): gate
  green, 649 ok checks, 682 s.
- 2026-10-29 · 306b38f · the build and tests are Tcl only (zef dc44127, and
  the candidate's PowerShell and C# removed; `tools\dev.tcl` merged by hand):
  gate green, 649 ok checks, 629 s.
- 2026-10-29 · c8e1173 · the console-control proposal, as zef imported it
  (zef 346948c): gate green, 649 ok checks, 799 s.
- 2026-10-29 · d29c268 · the bootstrap refuses steering variables and runs
  bash without profiles (bc6a4a3's hardening; B4, B13): gate green, 649 ok
  checks, 685 s.
- 2026-10-29 · c64ec38 · the gate runs the candidate's test groups in a clean
  lane environment: gate green, 36 steps after the build, 1,751 ok checks,
  1,352 s (figures recorded in 2be5c9e).
- 2026-10-29 · 2be5c9e · the candidate's entry, reference and application
  identity tests in Tcl: gate green, 38 steps, 1,897 ok checks, 1,377 s.
- 2026-10-30 · 75a600b · native analysis in Tcl, and the UB-trapped drivers
  as gate steps: gate green, 58 steps, 2,113 ok checks, 1,376 s.
- 2026-10-30 · 2a39777 · the release build publishes in one operation again
  (B7, in part): gate green, 58 steps, 2,114 ok checks, 1,242 s.
- 2026-10-30 · 6799d2b · the development checks are the Tcl gate's groups:
  gate green, 58 steps, 2,114 ok checks, 1,158 s.
- 2026-10-30 · c9cbff2 · version 22, one natural number, in preparation (zef
  840fbc2 and 3c8e98a for machteld, extended to the candidate's tools): gate
  green, 58 steps, 2,133 ok checks, 1,146 s.
- 2026-10-30 · 735b738 · machteld is a compact Windows runtime for Tcl/Tk 9
  programs (the owner's wording): gate green, 58 steps, 2,133 ok checks,
  1,154 s.
- 2026-10-30 · db7a2f5 · the els method is the guide
  `machteld/guide/els-method` (z df38fae): gate green, 58 steps, 2,141 ok
  checks, 1,163 s.
- 2026-10-30 · f6393df · the streaming-bounds overflow check no longer races
  its fixture's descendant (B16; a gate run of 03:00 had failed on it): gate
  green, 58 steps, 2,141 ok checks, 1,175 s.
- 2026-10-30 · ffac425 · the agents' commentary on the runtime, from zef, with
  two entries of 2026-10-30: gate green, 58 steps, 2,141 ok checks, 1,215 s.
- 2026-10-30 · 4e0a6db · BUILDING.md: the build PC, its three interpreters and
  the two-machine policy: gate green, 58 steps, 2,141 ok checks, 1,326 s.
- 2026-10-30 · the commit that adds this plan · this plan, and the README for
  22 in preparation: gate green, with its figures in the commit message.

<!-- machteld-version-history: end -->
