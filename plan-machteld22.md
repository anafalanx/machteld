---
type: plan
title: Machteld release implementation plan
status: Active 0.30 plan, updated 2026-11-25. Includes the decisions and evidence
  from the unsigned 22 development milestone.
relates: README.md, BUILDING.md, commentary.md, docs/roadmap.md,
  docs/direction.md, docs/creed.md, tools/stabilization.json
---

# Machteld release implementation plan

## 0. How to read this

**Deliver 0.30 directly after signed 0.21.** The owner closed 0.22 as an
unsigned development milestone on 2026-11-25. The 0.30 development checkout reports
`30`. The
existing signed 0.21 executable builds and tests every 0.30 candidate,
including the signed release copy. Work-item numbers such as 30.4 identify
milestones. October's records used the earlier number 23 for the successor.
The final section contains the implementation and release gates.
[Capability decisions](docs/roadmap.md)

On 2026-11-25, the Windows acceptance run passed 72 release and desktop
steps on unsigned Beta 1, built from `e0db215`. This candidate adds
supervised Tcl jobs, the upstream SQLite binding, script and archive launch,
atomic file publication, process-owned locks and Windows desktop services.
The owner selected all those features for 0.22, including wrapped
applications' custom Windows metadata and icons. The 72-step result
applies to that beta. The reconciled baseline at `eccba70` passed local
and hosted gates. Cross-host reproducibility and fresh acceptance of the
complete 0.30 candidate are release requirements. Sections 6.3 and 6.4
record the original preparation decisions and the direct-release decision.
[Beta 1 and release checklist](https://github.com/anafalanx/machteld/pull/5) ·
[Windows acceptance run](https://github.com/anafalanx/machteld/actions/runs/45597853161)

Four kinds of statement appear here:

- **Rulings**: what the owner decided on 2026-10-29 (section 1) and on
  2026-10-30 (section 6, with each ruling's reason and how it is applied),
  and the rulings in force before (section 3).
- **Proposals**: the plan's substance, each grounded in what was read or
  measured, with its date.
- **November decisions** (section 6.3) cover release scope, unsigned CI,
  reproducibility, build paths, the reference cache, required runtime
  acceptance, and how the reconciled source reaches GitHub `main`.
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

<!-- machteld-version-history: begin -->

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
   is the runtime's own: the console-control proposal (machteld's own text,
   documentation only: machteld 287702b, which zef imported in 346948c), the
   agents' commentary, the els method, BUILDING.md and this plan. On the way
   it fixed a test race the gate met (B16). Then the owner's rulings of
   2026-10-30 (section 6) took application identity's stamping out to 23
   (0f62438).
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
   a newer runtime names an upper bound, which Tcl excludes (`22-30`). The
   signed 0.21 executable remains the build driver through 0.30 acceptance.
2. **The creed and the direction** (`docs\creed.md`, `docs\direction.md`).
   The runtime uses Tcl/Tk with native C and C++. Tcl drives the build and
   tests. The hosted Windows workflows can use PowerShell to set up the
   runner and invoke the project's tools.
3. **The candidate's constraints** (`tools\stabilization.json`). The repository
   was private when the candidate was prepared and is now public. Release 22
   preserves the released artifacts and wrap's documentation opt-in. Its
   languages are Tcl/Tk and native C/C++, with no engines, Lua or
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
5. **Unsigned builds and signing.** The build PC and hosted CI may build and
   test unsigned executables. Hosted CI keeps those executables inside the
   verification job. The owner signs a release copy on the build PC. Other
   machines run signed releases. Section 6.3 records the revision to the
   October two-machine policy.

## 4. The October scope for 0.22

The October plan called for the candidate's stabilization, the build in
Tcl and the ledger's remaining fixes in one signed `machteld.exe`.
Ruling 2 limited that scope to stabilization. The November vote adopted the
full Beta 1 scope and custom wrapper identity for the release.

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
  (7a15542) and explicit inventories (`--manifest`, `--plan`). The
  documentation's corrections of documented behavior (the stabilization's
  step 11).
- **The consolidation.** The release build, bootstrap, reference generator,
  gate, development loop, native analysis and every driver test in Tcl
  (b0c4edc, 306b38f, 2be5c9e, 75a600b), with the candidate's hardening
  carried in: the bootstrap refuses steering variables, runs bash without
  profiles and records the effective toolchain's fingerprint (d29c268); the
  test groups run in a clean lane environment (c64ec38); the release build
  publishes in one operation (2a39777). Version 22 and the owner's wording
  (c9cbff2, 735b738). The console-control proposal, as documentation only
  (c8e1173: machteld's own text at 287702b, as zef imported it in 346948c),
  the design input for console control in 0.30 (4.3, section 8). The els
  method as a guide, the streaming-bounds test's race fixed, the commentary,
  BUILDING.md and this plan (section 7).
- **Not carried from zef:** its rename (840fbc2) and everything of the
  environment (`zef.tcl`, `verbs\`, `lib\`, pins, settings, the Go ignition,
  the TypeScript, `DESIGN.md`), with zef's phases and decisions for its
  editor, the agents' homes, backup, the work PC, its verbs and its namespace.
- **Not ported from the candidate:** the reference stage cache, with its
  PowerShell and C# serializers (D5).
- **October deferrals.** Commit 0f62438 removed custom wrapper metadata and
  icons under ruling 1. The `app-identity` branch preserved the implementation.
  Section 6.3 brings this feature and the cumulative Beta 1 runtime additions
  into 0.22. Ruling 3 places the FFI in 0.30.

### 4.2. The bug ledger

The mapping pass of 2026-10-28 (`result.bugs` in the mapping) checked every
item against zef's core and against the candidate. The research of
2026-10-29 added R26-R29 and checked them in this branch's source that day.
The consolidation re-checked R16 on 2026-10-30, and its gate runs and review
added B15-B17 and the GUI host's wording. The other items stand as mapped
until each is fixed or checked again. Each new fix lands with a regression
test that fails before it.

The table records the October assessment. Beta 1 fixed `scope` propagation
(R1) and the ACL fixture's PATH-dependent tool lookup (B15). It also added
metadata-only path queries and quiet, supervised workers. Recheck the
remaining items on the reconciled source. The locked-file, default console
and detach paths need their own evidence. Record a regression result or
an explicit deferral for every outstanding item before signing.

| Fixed in the candidate (8bcc1ec), carried | R2 help, R3 json NUL, R4 typed null, R10 key leaks, R18 interp cleanup, S2 pool stderr eof; json bytearray as Latin-1; typed depth; recycled channel names; reentrant child close; pool close in callback; store leaks; NUL paths; hash counter |
|---|---|
| New fixes in 22 | R1 scope -level; R5 -stdin broken pipe; R6 kill after exit; R7 canon on a locked file; R8 detach console and process group; R11 capture race; R12 strict text from -onout and store keys; R13 -env block size; R14 pty_free; R15 dead code; R16 breakaway (merged with the limits write); R17 one size grammar; R19 comments; R22 PATH from -env; R24 cli parse name; R25 bytearray docs; S3 watch overflow; S4 worker non-error codes; S7 creed wording (its rewording done in c9cbff2); -onout read errors; long resolved paths; crash containment (no error dialogs from children); R26 one package search in every interpreter; R27 registry and dde registered; R28 handle tokens unique across the process; R29 panic containment; the GUI host's file description and product name in the owner's wording |
| Deferred to 0.30 | R9 the polling monitor (a completion-port supervisor is a redesign; the `-onout` pump polls the same way, `src\proc.c:1243`, and read 16 MiB in 3 to 11 s on the build PC); R20 limit status; S1 incremental UTF-8 for pty; S5 GUI fatal message; S6 bounded reap; R21 rename pairing across reads; R23 narrowing the global path |
| Build, done | B12 BUILDING.md's interpreters (BUILDING.md); B13 toolchain fingerprint (d29c268); B16 the streaming-bounds overflow check raced its fixture's descendant, whose newline split the overflowing line when the pump was slow (found and fixed in f6393df) |
| Build, partly | B3 retried renames (the development cache's publications in 306b38f, the release build's in 2a39777; `tools\reference.tcl`, `tools\package.tcl` and `tcl\docs.tcl` still rename once); B4 bash profiles (d29c268; the bash steps have no timeout yet); B7 publish semantics (2a39777: one operation, and debris checked; not write-through, retried on any error); B10 a development build must not overwrite a signed exe (the gate's build goes to `out\machteld.exe` only, since it refuses `--runtime` when it builds; where the development loop publishes is D4) |
| Build, open | B1 detach coverage (with R16); B2 tolerant cleanup; B5 curl timeouts and tar checks; B6 MSYS2 discovery (BUILDING.md names `--msys` and `MSYS2_ROOT`; `tools\dev.tcl` takes no `--msys`); B8 attribute checks; B9 cache-path match; B11 publish only after every lane passed (ruling 10); B14 a signing recipe (at release, BUILDING.md); B15 the entry test runs `whoami.exe` by bare name (`test\entry_test.tcl:145`), so a caller's PATH with Git's tools first gives its ACL fixture no SID (found in c9cbff2's first gate run, from Git Bash); the fix names System32's `whoami.exe`, and until then the gate runs from PowerShell; B17 the development build lock's stale-lock race (below) |

The newer items, in full:

- **R26, one package search in every interpreter** (ruling 6). TCL_LIBRARY,
  TCLLIBPATH, TCL9_0_TM_PATH, TCL9.0_TM_PATH and `<exe>\..\lib` steer every
  interpreter today: TCL_LIBRARY sends `interp create` children to a decoy
  `init.tcl`, and a planted msgcat 1.7.99 replaced the embedded 1.7.1 and
  broke `clock format` (the research's probes). Fix: one process-wide
  `Tcl_SetPreInitScript` in both hosts, decoy tests first; programs add their
  folders explicitly (`lappend auto_path`, `tcl::tm::path add`). `src` has no
  `Tcl_SetPreInitScript`.
- **R27, Tcl's own registry 1.3.7 and dde 1.4.6** (ruling 7): linked in
  `libtcl90.a` and announced by `Tcl_Init`, never registered, while their
  reference pages ship. Fix: two `Tcl_StaticLibrary` lines, about +48 KB
  across the three copies in `machteld.exe`. `src` has no `Registry_Init`
  or `Dde_Init`.
- **R28, handle tokens unique across the process.** A `hash#1` minted in one
  interpreter consumed another interpreter's `hash#1`: the counters are per
  interpreter (`src\proc.c:872`, `1830` and `2340`, `src\hash.c:238`,
  `tcl\pool.tcl:116`). Fix: one counter for child, pty, watch, hash and pool
  tokens; a foreign token raises `{MACHTELD X nohandle}`.
- **R29, panic containment.** There is no panic proc and no error mode, so a
  `Tcl_Panic` in the GUI host opens a task-modal, foreground "Fatal Error"
  box (`tclWinFile.c:825-856`), and both hosts then trap into Windows Error
  Reporting; the candidate's json port makes out-of-memory a deliberate
  panic. Fix: a panic proc that writes to stderr when there is one and exits
  with a fixed code, installed after Tcl_Main's own, and
  `SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX)` at host start.
  `src` has no `Tcl_SetPanicProc` or `SetErrorMode`.
- **The GUI host's wording.** The GUI host's FileDescription and ProductName
  still read "Machteld GUI application host" and "Machteld"
  (`tools\generate-version-resource.tcl:51` and `:81`; the product name is
  the console host's too), where the owner's wording gave the console host
  the file description "machteld runtime" (735b738); the wording step left it
  for the ledger.
- **B17, the development build lock's stale-lock race.** `tools\devcache.tcl`
  takes over a stale lock in three separate steps (`:192-193`: the
  staleness check, the delete, then the next exclusive create), so two
  development builds that both see the same stale lock can both run in
  `.cache\dev`. It affects only the development loop. Fix: an atomic
  takeover, with a test of two processes.

### 4.3. Candidates for 0.30 and later

The October poll deferred these proposals under ruling 2. The November
vote admitted the beta's quiet-worker option, `lock try` and `lock release`,
and `publish bytes` and `publish file`. These implemented APIs supersede
the October sketches for the corresponding operations. The remaining
candidates came from zef's verbs (zef's plan, its section 4.3; the commentary's
entries of 2026-10-28), and machteld builds no development environment, so
none is admitted for that reason: each must still pass direction.md's first
admission question, whether it strengthens what machteld is strongest at, for
many programs, beyond what they can do in Tcl. The ledger's defect fixes stay
in 22 even where they touch the same code: R8 (detach shares the host's
console and process group), R16 (no job of the runtime's allows breakaway;
merged with the limits write) and the crash containment for children.

1. **Console-less launches:** captured children without a console window of
   their own, so a host without a console (a `wrap --gui` tool) opens none per
   child; `detach` without the host's console, in a process group of its own
   (the defect half is R8).
2. **detach -breakaway:** `detach -breakaway required|preferred`, where
   `preferred` starts the program inside an enclosing job that forbids
   breakaway (the defect half, the runtime's own jobs, is R16).
3. **Console control,** in the proposal's own surface
   (`docs\proposals\console-ctrl\README.md:35-37`): `console ctrl ignore`,
   `console ctrl default`, and a bare `console ctrl` that returns the mode in
   force, so that a program that hands its console to a child can let the
   child decide what Ctrl-C means. The proposal, with its working code, is
   the design input (section 8). zef's later design, `console ctrl
   default|catch` with `console interrupts` and no `ignore` (children inherit
   it), is recorded in the zef-22 plan (`plan-zef22.md`, its 4.3 item 4 and
   D7), preserved in `C:\dev\.preserve\2026-10-29-zef-22-branch`.
4. **A lock:** `lock take path ?-timeout d?` and `lock release`, a
   `LockFileEx` lock that Windows releases when its holder ends; Tcl can only
   create a file exclusively, which a crashed holder leaves behind.
5. **Publish as a command:** the atomic replacement behind `wrap` and the
   release build, `::machteld::Publish`, documented, perhaps with `-wait`.
6. **dirs -entries:** files too, each with its kind, size, modification time
   in 100-ns units and attribute word, from the one enumeration `dirs`
   already does: what a backup, a sync or "what changed since" needs. The
   attribute word would also bring back B8's checks.
7. **The hidden desktop:** `run`, `child start` and `pty spawn` on a desktop
   of the host's own, so that what a tool starts never takes the user's
   keyboard focus.
8. **The small options:** an exact environment for children (`-clearenv`),
   `http get -to FILE`, `-encoding` on capture, `canon` attributes and times,
   `-priority` and `-stderr stdout`.
9. **A shortcut:** `shortcut write|read`, through `IShellLink`.

`cli parse` naming the program is a fix, not a feature (R24).

## 5. Original phases for the 22 milestone

The October plan assigned no feature phase to 0.22. The first November vote
added Beta 1. The following phases record the original plan. Section 6.4
supersedes its signing, publication and driver-adoption steps.

0. **Preserve** - done: the candidate's read-only snapshot,
   `C:\dev\.preserve\2026-10-28-machteld-0.22-candidate` (verified when made);
   the candidate committed as left (8bcc1ec); zef's `zef-22` branch,
   `C:\dev\.preserve\2026-10-29-zef-22-branch`.
1. **Baseline** - done: 8bcc1ec.
2. **Consolidate** - done (section 7): the build in Tcl, the candidate's
   tooling carried into it, version 22, the owner's wording, and the
   runtime's own knowledge from zef. Every commit gated green. Then the
   rulings of 2026-10-30 (0f62438 and this plan).

The original remaining phases were as follows.

3. **The ledger** (4.2), test first: each fix with a regression test that
   fails before it, grouped by severity. A group is integrated with the tests
   of what it touches, then checked once by the full gate and reviewed
   adversarially (the owner, 2026-10-30: integrate well first, then check).
4. **The docs:** each fix's guides and pages change with it (R26's package
   search and R27's registry and dde among them); then the README, the guides
   and the reference are read against 22 as built, and the release notes are
   written.
5. **The release, on the build PC:** the roadmap's release gate, the
   candidate's step 12. Freeze the source and produce two independent clean
   unsigned builds. Require matching SHA-256 hashes, compare the matching
   incremental build, and run the full gate on the candidate. Automate repeatable
   desktop checks in isolation and verify user-visible behavior in an attended
   session. Arrange the remaining owner tests before release (ruling 12):
   `--public-tls`, `--interactive-pty`, `--interactive-gui`, and
   the detach success path from a shell outside any job that forbids
   breakaway; the owner signs a copy at a release path, never
   `out\machteld.exe` (BUILDING.md); the gate on the signed bytes
   (`--skip-build --runtime FILE`); release notes, with the signed file's
   SHA-256. A GitHub release like 0.21 follows on the owner's word (ruling
   15).
6. **After the release:** the build tools move from the signed 0.21 to the
   signed 22 (`package require machteld 22-`), in a commit of their own,
   gated on the signed 22.

zef's phases for its verbs (its phase 5), zef on the build PC (7), the work
PC's swap (8) and its projects standing alone (9) are the environment's, and
are dropped.

<!-- machteld-version-history: end -->

## 6. Rulings

The owner's rulings, each with its reason, drawn from the research's draft of
2026-10-29 and the consolidation's re-cut proposals, and how it is applied.
They replace the re-cut decisions they settle (D1, D2, D3, D6, D7 and D8) and
the three topics that were under research (FFI, the Thread package and Tcl
packages), whose studies are
`C:\dev\.preserve\2026-10-29-ffi-thread-packages-research.json` and, for
Thread, `C:\dev\.preserve\2026-10-29-thread-studies-journal.jsonl`. Elsewhere
in this plan, "ruling N" is the poll's ruling N (6.2).

### 6.1. 2026-10-29

- **The name and the version** (section 1, item 1): machteld again, and one
  natural number from 22 on. *Why:* only a change to the runtime makes a new
  number. *Applied:* c9cbff2.
- **The repository holds the runtime only** (section 1, item 2). *Why:* "We go
  back to just building machteld"; the development environments built with it
  get local-only repositories and are not machteld's business. *Applied:* the
  consolidation (section 7); nothing of the environment comes in.
- **The wording** (section 1, item 3). *Why:* the product sentence is also
  direction.md's admission filter. *Applied:* 735b738.
- **Tcl's Thread package is not admitted** ("We won't include it"). *Why:* no
  program in `C:\dev` needs it, a warm worker process answers nearly as fast
  (0.29 ms against 0.15-0.24 ms), and measured on 0.21 it defeats supervision
  (`thread::cancel` cannot stop a native call, async errors reach `bgerror` or
  only the worker's stderr, `exit` in a worker ends the process, bytearrays
  change across a send, synchronous errorCodes arrive wrapped), while upstream
  it has no maintainer and no Windows CI. *Applied:* warm pool workers and
  evented natives in its place, for 23 (section 8). The study's run was
  stopped on the owner's word before its skeptics ran.

### 6.2. 2026-10-30: the decisions poll

This section records the October answers. Section 6.3 supersedes the October
answers on release features, wrapper identity, unsigned CI, desktop
acceptance and integration into `main`. The November vote also admits the
SQLite binding under ruling 8. Ruling 2 was
asked again, because the multi-select had not come through, and ruling 1 was
completed in the morning, after the owner asked what application identity
is.

1. **Application identity: its stamping moves to 23, and "Keep the file
   list".** *Why:* without it 22 is the smaller release, and its native parser
   of ICO and PE bytes, which zef's plan had also left out of zef 22, goes with
   it; the explicit file list is what keeps unrelated and secret files out of
   a wrapped tool. *Applied:* 0f62438
   removes the manifest's `metadata` key (name, version, description, author,
   publisher, copyright, icon), the icon reading, `src\resource.c` and its
   registration, the metadata facts in `--plan`, and their docs and tests; a
   manifest with `metadata` is refused as not part of this version.
   `--manifest` with `schema 1` and `files`, `--plan` and the whole-directory
   default stay. The branch `app-identity` keeps bec1289. The November
   archive decision in section 8 supersedes the proposed revert. The poll had called
   `--manifest` a Windows manifest; it is machteld's own inventory file.
2. **Runtime features: "None in 22".** *Why:* 22 is the stabilization's
   release and its release gate is not done; each feature needs a design, a
   manifest entry, a page, tests and acceptance; and the needs came from one
   environment's verbs, not yet from many programs. *Applied:* the nine are
   candidates for 23 and later (4.3), each still to pass the admission
   question; the ledger's defect fixes stay in 22 even where they touch the
   same code (R8, R16, the crash containment for children); the owner's
   window tests run at release, without a hidden desktop.
3. **The FFI: in 23.** *Why:* cffi 2.0.3 (BSD-2, the only maintained Tcl 9
   FFI, about 1,400 tests) is the widest step beyond what programs can do in
   Tcl, about 10-13 agent-days, and the study had recommended 23. *Applied:*
   23's first bundle (section 8); nothing of it in 22.
4. **The FFI's DLLs: Windows' own and the program's own, no callbacks.**
   *Why:* libffi closures are read-write-execute memory on Windows, and
   cffi's callbacks have no thread or lifetime guard (its issue #122), so
   callbacks wait for a named need. *Applied:* Windows' DLLs by bare name from
   System32 only, a program's own by absolute path, never the current folder
   or PATH; no callbacks; the contract's "Foreign calls" lands with the FFI in
   23.
5. **Patches to vendored sources: yes, recorded and tested.** *Why:* without
   machteld's four patches cffi would ship with its defects documented (lossy
   text, a DLL search through the current folder and PATH), and the bootstrap
   applies only the exact upstream correction the lock names. *Applied:* lock
   entries get a kind (upstream, backport, machteld) with their reasons,
   before and after hashes and a regression test; machteld's own are offered
   upstream only on the owner's word; the bootstrap's one-patch assertion
   becomes a list when the first such patch arrives.
6. **Package search: only from machteld.exe, in every interpreter.** *Why:*
   TCL_LIBRARY, TCLLIBPATH, the module path variables and `<exe>\..\lib` steer
   every interpreter today, and the research's probes sent `interp create`
   children to a decoy `init.tcl` and broke `clock format` with a planted
   msgcat. *Applied:* R26 in 22, one process-wide `Tcl_SetPreInitScript`,
   decoy tests first; programs add their folders explicitly. Tcl 9.1's TIP 732
   removes that hook, so a Tcl move redoes it.
7. **registry and dde: both.** *Why:* Tcl's own packages are linked and
   announced but never registered while their reference pages ship, and
   registering both costs two `Tcl_StaticLibrary` lines and about 48 KB.
   *Applied:* R27 in 22; the runtime itself never writes the registry.
8. **Libraries: machteld's own commands, plus ones admitted one at a time.**
   *Why:* a curated tcllib subset would add about 1 MB and make its
   vocabulary de facto contract, and all of tcllib about 7.6 MB with its
   docs. *Applied:* no tcllib or other library is built in; tcllib, twapi,
   tklib, TDBC, the sqlite3 binding, Itcl and image or drag-and-drop
   extensions belong to the programs, pinned in their own folders under the
   extensions covenant; a third-party organ comes in only by the admission
   questions and a ruling (cffi in 23).
9. **The Tcl version: stay on 9.0.4.** *Why:* Tcl 9.1 (2026-09-30) would put
   registry in the core, but TIP 732 reworks init (R26 redone), cffi needs
   2.0.4 or later (unreleased), and the corpus and the Tcl patch would be
   redone; a Tcl move is its own release decision. *Applied:* 9.0.4 through
   22 and 23.
10. **The build tools: as the consolidation builds them.** *Why:* in the
    poll's words, the gate runs every release lane and publishes only when
    all pass, with one Tcl version checker and a development loop without
    PowerShell. *Applied:* the tools of section 7; publishing
    `out\machteld.exe` only after every lane passed, the re-cut's D3 (b), is
    B11 in the ledger.
11. **The ledger: a dated log in the plan.** *Why:* a line per commit with its
    gate result keeps 22's evidence beside the plan it carries out.
    *Applied:* section 7; `tools\stabilization.json` stays the candidate's
    record.
12. **Tests that need the owner: before the release, each on the owner's
    word.** *Why:* `--public-tls` contacts public hosts, `--interactive-pty`
    and `--interactive-gui` need the console and open windows, and no gate
    run reaches the detach success path, because the gate's own jobs forbid
    breakaway (R16). *Applied:* phase 5; the window tests without a hidden
    desktop (ruling 2).
13. **Unsigned builds: only on this build PC.** *Why:* the build PC builds and
    tests, signing is the owner's step, and other machines run signed
    releases only (3.5). *Applied:* BUILDING.md.
14. **An off-disk copy: push the work branch to GitHub.** *Why:* one disk held
    every copy. *Applied:* `machteld-22` pushed to origin at 2a39777, and
    again after each green stage (section 7); origin's `main` stays at the
    0.21 release.
15. **Publishing 22: a GitHub release like 0.21.** *Why:* 0.21 was published
    so: tag v0.21, with its signed executable, release notes and
    `SHA256SUMS.txt`. *Applied:* at release, on the owner's word (phase 5).
16. **`C:\dev\_zef`: delete once the consolidation is done.** *Why:* what 22
    needs of it is carried over (4.1), the rest is preserved, and its design
    is the one these rulings reverse. *Applied:* moved to the Recycle Bin on
    2026-10-30, once the consolidation's result was verified; it can be
    restored exactly from `C:\dev\.preserve\2026-10-29-zef-22-branch`
    (bundle and patch).
17. **The name route: in 23.** A renamed copy of `machteld.exe` runs the
    same-named script beside it. *Why:* "a signed front door for any
    environment" (the poll), and 22 is full. *Applied:* section 8.
18. **A GUI twin of `machteld.exe`: no.** *Why:* Tk tools wrap with `--gui`.
    *Applied:* rejected. Section 8 records how a desktop app will launch
    once `wrap` retires.

### 6.3. Release preparation decisions (2026-11-25)

The consolidation re-cut zef's decisions D1-D15 to eight that concern the
runtime: zef's scope (D3) became D1 and D2; the gate (D9) D3; where the
development loop publishes (from D11) D4; the release ledger (D12) D6; the
owner's acceptance (D13) D7; the signed runtime's way to the work PC (D15) D8,
publishing the release; and D5, the reference stage cache, was new. Of zef's
others, the two machines (D1) are section 3.5, the candidate is committed
(D2b, 8bcc1ec), wrap's reference opt-in (D4) is in since 7a15542, the version
checks (D10) keep the candidate's markers, extended to natural numbers
(c9cbff2), and the development loop (D11) decides by content (306b38f); one
API per feature (D7) waits for a feature to be admitted; and the
environment's were dropped: a plain copy of `C:\dev` (D2a), the front door
for zef's verbs (D5), zef's own namespace (D6), the runtime range in
`zef.tcl` (D8) and zef on the build PC (D14). The October poll settled six
of the eight decisions. Rulings 1, 2, 10, 11, 12 and 15 covered D1, D2,
D3, D6, D7 and D8 respectively. The November poll settled D4 and D5.

The following numbers match the November release poll.

1. **Release scope.** Ship the cumulative Beta 1 feature set. It includes
   `machteld::job`, the upstream SQLite binding, direct Tcl entry, `pack`
   and archive launch, same-generation archive workers, publication and locks,
   quiet and attended child windows, metadata-only path queries, clipboard
   ownership and corrected `scope` control flow. Freeze and gate the
   reconciled source before release.
2. **Wrapper identity.** Keep console and GUI `wrap`, explicit file lists,
   `--plan` and optional Windows metadata and icons for 0.22. The 0.30
   roadmap covers migration to archive delivery and retiring the wrappers.
3. **Unsigned builds.** The build PC and hosted CI may run unsigned builds.
   CI executables remain inside the job. Record results and checksums
   without distributing the unsigned binaries. The owner signs release
   copies on the build PC for use elsewhere.
4. **Clean-build reproducibility.** Require two clean unsigned builds of the
   final source to yield byte-identical executables before signing. In Beta 1,
   the PE prefix and the contents of all 2,306 archive entries matched while
   the ZIP container bytes differed. Compare complete executable hashes on
   the release candidate and retain the clean versus incremental comparison.
5. **Build outputs (D4, B10).** Incremental builds and their tests use
   `out\dev\machteld.exe`. Reserve `out\machteld.exe` for the release gate.
   Standalone clean builds default to `out\candidate\machteld.exe`. The
   owner signs a copy in a dedicated release directory.
6. **Reference cache (D5).** Keep the whole-generation content cache for
   0.22. Unchanged inputs reuse a generation. A documentation edit rebuilds
   the reference in about a minute on the build PC.
7. **Desktop acceptance.** Automate repeatable GUI checks on an isolated
   desktop. Verify user-visible behavior, including foreground window
   presentation, in an attended desktop session before release. Record each
   result against the candidate and the Windows target tested.
8. **Application acceptance.** The runtime gate covers its regression
   checks and packaged examples. The porting project tracks profile
   migration, backup and restore, updates and attended sign-in separately.
9. **Git history.** Reconcile the source on `main` with ordinary commits.
   Preserve commit ancestry, branches and release tags.
10. **Push to GitHub.** Push the reconciled source directly to GitHub
    `main` after its checks pass. Signing and release publication are
    separate owner decisions.

### 6.4. Direct release decision (2026-11-25)

Signed 0.21 is the upgrade source and the build driver. Preserve the 22
commits, existing tags, Beta 1 receipts and reconciled source as history.
Close the standalone 0.22 release work. Apply the preparation decisions on
build outputs, unsigned CI, reproducibility, attended checks, signing and
publication to 0.30. The approved ownership poll assigns 25 capabilities
to the shared executable. Applications supply system-wide hotkeys. The
independently installable runtime and the application archive replace
executable-producing `wrap` for new delivery.

For 0.30 the release gate tests an invocation-owned candidate and promotes
it to `out/machteld.exe` only after every selected step passes (B11).
The bootstrap checks cache containment using the literal Windows path (B9).
The development build keeps the cache lock open throughout its critical
section, including publication, so a stale-lock contender cannot displace
a live owner (B17). The signed 0.21 driver exercises failed promotion,
bracketed cache paths, and competing lock owners.

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
- 2026-10-30 · e9e5d2f · this plan, and the README for 22 in preparation:
  gate green, 58 steps, 2,147 ok checks, 1,222 s.
- 2026-10-30 · 502896b · the gate refuses `--runtime` when it would build over
  it (B10, in part), and the docs say what a gate run publishes (the
  consolidation's review): gate green, 58 steps, 2,150 ok checks, 1,208 s.
- 2026-10-30 · fc1b4af · native validation runs its scaling lane and the full
  native analysis in every run again, as the candidate's group did, and every
  undefined-behavior-trapped step has a deadline (the consolidation's review):
  gate green, 60 steps, 2,190 ok checks, 1,407 s.
- 2026-10-30 · bec1289 · the README links the 0.21 release instead of a file
  git ignores, and a local link must name a file every clone has (the
  consolidation's review): gate green, 60 steps, 2,192 ok checks, 1,288 s.
- 2026-10-30 · the pushes (ruling 14): `machteld-22` to origin
  (github.com/anafalanx/machteld) at 2a39777 (00:53), 6799d2b (01:21),
  db7a2f5 (03:19), e9e5d2f (05:19) and bec1289 (07:19), each after a green
  gate; origin's `main` stays at the 0.21 release (8ad9507).
- 2026-10-30 · `C:\dev\_zef` moved to the Recycle Bin once the consolidation's
  result was verified (ruling 16); it can be restored exactly from
  `C:\dev\.preserve\2026-10-29-zef-22-branch` (bundle and patch).
- 2026-10-30 · 0f62438 · application identity's stamping out to 23, the file
  list kept (ruling 1); the branch `app-identity` keeps bec1289, and a first
  attempt that also removed the file list was stopped before it committed:
  the fast and packaging groups green on a development build, 24 steps, 1,260
  ok checks, 531 s; the full gate once, after the next commit.
- 2026-10-30 · the commit that adds this line · the plan takes the owner's
  rulings with their reasons (section 6), R26-R29, B17 and the GUI host's
  wording in the ledger, the candidates for 23 and later, the phases that
  remain, the console-control proposal in the account of what came from zef,
  and a section for 23; the roadmap's console-control paragraph is a
  candidate for 23 without the environment, and its 22 section no longer
  credits 22 with the candidate's reference conversion caches: the docs
  checks and the fast group green on a development build; the full gate runs
  once on this tree, and the next entry records it.

<!-- machteld-version-history: end -->

## 8. Plans for 0.30

The roadmap records the 26 ownership decisions and their implementation sequence.
The items below collect the earlier design rulings by topic.
New commands go through the admission questions. The candidates of 4.3
and the ledger's deferred items (4.2) supply further design input. [Roadmap](docs/roadmap.md)

1. **The FFI, the first bundle planned for 0.30** (rulings 3–5). cffi 2.0.3 (BSD-2, Ashok
   Nadkarni) on libffi 3.5.2 (MIT), statically linked in the runtime and loaded only on
   `package require cffi`, built without callbacks, so no executable memory.
   Four machteld patches, recorded and tested: no callbacks; a loader that
   searches only System32 or the given absolute path; strict UTF-16 text; no
   debug sandbox command. The DLL rule: Windows' own by bare name from
   System32 only; a program's own by absolute path, with its dependencies
   from its folder and System32. cffi keeps its own commands, pages and error
   codes, and the palette gains no command. With it, `docs\contract.md` gains
   "Foreign calls" (no safe interpreters; a declaration is an unchecked
   promise and a wrong one is undefined behaviour; cffi's error codes; the
   loader rule; strict UTF-16 through W functions; no callbacks; who frees
   memory and handles; blocking and crashes, with calls that may crash
   belonging in a pool worker). Update the manifest description at 30.4a.
   Creed 8 gains one sentence, and direction.md's placement list gains
   "one synchronous call
   into a Windows DLL with no lifetime beyond the call: declare it through
   cffi in the program". Its prerequisites, R26 and R29, land in 22.
2. **Warm pool workers** (30.8): a pool takes successive
   batches and single calls and announces completion through the event loop,
   with an opaque token. Preserve Job Object termination, deadlines and
   memory caps. The existing `app launch` prefix pins the running archive
   generation across updates. Extend this guarantee to reusable workers
   and check the expected digest before executing application code.
3. **Evented natives** (in place of Thread): evented variants of the commands
   that block for long, whose native threads do the work and deliver
   completion with `Tcl_ThreadQueueEvent`, never evaluating Tcl off the main
   thread, with cancellation points. The 0.22 `machteld::job` package already
   delivers worker records through the event loop. Milestone 30.2 covers
   native child-completion notifications.
   Cancellable HTTP follows at 30.7, including progressive delivery of
   binary response chunks with bounded buffering. Other candidates include
   `hash file`, `dirs`/`links`, and readiness events for `watch` and `pty`.
4. **One runtime for scripts and archives.** Both `machteld.exe app.tcl` and
   `machteld.exe app.machteld` run in 0.22. For desktop shortcuts in 0.30,
   keep the Windows console subsystem and embed `consoleAllocationPolicy`
   with the value `detached` in the runtime manifest. Verify on the supported
   Windows targets that a shortcut opens a Tk app without a console flash and
   that a foreground launch from a terminal preserves standard streams,
   redirection, shell waiting and exit status. Pass application arguments
   through in both cases. Ruling 17 also allows a renamed copy of the signed
   runtime to find its same-named script.
5. **Keep archives as the standard and restore optional standalone wrapping.**
   The original 30.4 milestone retired the executable packager. The owner
   subsequently chose to restore console and GUI `wrap` in the full host.
   The app can supply its own Windows name, version, description, publisher,
   copyright and icon. Wrapped executables omit the offline manual. Any signing
   happens outside Machteld. Qualify this delivery path alongside the shared
   runtime, renamed companion scripts and `.machteld` archives.

   Build and run applications with the same signed `machteld.exe`. In 0.22,
   `pack` takes a directory with a root `main.tcl` or a single Tcl script.
   Extend it to accept a project manifest naming the entry point and
   selected files. The proposed arguments are illustrated by
   `machteld.exe pack app.dict -o app.machteld`.
   Use Tcl's bundled ZIP writer to create an application-only archive with
   file sizes and hashes. Verify the result and publish it atomically.
   On archive launch, add verification of that inventory before running
   the entry script from the mounted archive.

   Test both commands in a clean directory containing only the release
   executable, a project manifest, an entry script and a fixture asset.
   Use the executable to create the archive, then run it away from the source
   tree and read the bundled asset. Both commands must work without a
   compiler, external ZIP program or separately installed Tcl/Tk. Also test
   an archive worker accessing its pinned generation after replacement.
   Verify that it detects a mismatch before running another generation's code.
6. **Console control** (4.3, item 3), with the console-control proposal,
   `docs\proposals\console-ctrl`, as its design input.
7. **SQLite full-text search.** The 0.22 runtime already exposes SQL through
   the upstream Tcl `sqlite3` binding, sharing the pinned engine with `store`.
   Enable FTS5 for documentation search. Ship the numbered-parameter helper,
   opt-in connection profile and verified, create-only backups described in the
   [roadmap](docs/roadmap.md). Applications own their query policies,
   schemas, migrations, backup schedules, retention and restore decisions.
8. **Graphviz layout and drawing for Tk, immediately after full SQL.** Embed
   the static Graphviz `dot` layout engine with orthogonal routing, HTML-like
   table labels backed by static Expat, and xdot drawing instructions. A Tcl
   program can obtain node positions and edge routes, and Tk can use the
   drawing instructions to paint positioned text, borders and cell fills.
   Pin the sources and include their notices in the runtime. Test a directed
   graph with right-angle bends and a table with named cell ports. Verify the
   drawing output and a Tk canvas example, run the layout in-process with
   only the runtime installed, and record the packaged size against a matching
   full-SQL build. The November 2026 prototype added 1.64 MiB with the
   packaging used for 22.
9. **Compact offline documentation for agents.** Keep one queryable reference
   with stable IDs, sections and bounded JSON. Use FTS5 in a read-only
   SQLite database for discovery and exact lookups for IDs and aliases.
   The packaged and exported reference consists of a single `reference.db`.
   Store Markdown page bodies and their FTS5 index in that database. Check
   all Tcl/Tk manual entries from the pinned sources and all shipped Machteld
   commands, packages and host features. Development retains the source documents.
   The “Compact offline reference for agents” section of the
   [roadmap](docs/roadmap.md) gives the size and retrieval checks.

Rejected: Tcl's Thread package (2026-10-29) and a GUI twin of `machteld.exe`
(ruling 18). Ruling 9 keeps Tcl at 9.0.4 through 0.30.

## Implementation and release gates for 0.30

The build starts from `eccba70` on `main`. Signed 0.21 is the driver in
`dist/0.21`, the dependency cache supplies the static Tcl build interpreter,
and the candidate is the executable under test. An implementation change
is complete when its public Tcl contract, code, platform fixtures, reference
entry, example and gate lane agree. Use small commits that can be reverted
independently. Keep application source, profiles and credentials in their
own repositories. Public regression fixtures use synthetic data.
[Build instructions](BUILDING.md) · [Capability contracts](docs/roadmap.md)

### Work sequence and exit criteria

| Work | Deliverable and condition for moving on |
| --- | --- |
| **1. Reproduce the baseline and open contracts (30.0–30.1)** | Capture the 0.21 driver hash, source SHA, commit timestamp, OS, tool and dependency receipts. Fix the manifest-input mismatch described below. Review the open stabilization ledger against current source and keep a failing regression fixture for each confirmed defect. Run the porting application's existing suite on signed 0.21 with its current extension and record runtime gaps separately from app failures. Agree on observable results, errors, cancellation and resource limits before implementing each API. |
| **2. First feature and process foundation (30.9, then 30.2–30.3)** | Introduce synchronous cffi with the pinned libffi and loader rules in section 8. Make the first feature change advance the header, Tcl prelude, generated Windows version resource, manifest, version checks and current docs to 30 together. Exercise exact and ranged package requirements, including rejection of the exclusive upper bound in `22-30`. Keep the build scripts on signed 0.21. Then deliver event-loop child completion, shutdown and initial window visibility. Test error paths, ownership and cancellation before other features depend on them. |
| **3. Single executable and archives (30.4a, 30.4)** | Implement the detached-console manifest and verified inventory in the entry, archive and packaging code. Exercise both the shared archive loader and the optional standalone packager. Check a wrapped app's Windows identity and confirm that it carries no offline reference. Run a legacy 0.21 wrapped tool, package its original Tcl sources as a 0.30 archive and launch through a desktop shortcut. Document differences in app identity and writable data paths. Exercise an existing 22 archive and document conversion if required. Verify terminal I/O, relocation and worker-generation pinning. Inventory hashes check contents. The signed runtime identifies its publisher. |
| **4. SQLite, then Graphviz (30.5, 30.5a)** | Exercise the same SQLite engine through `store` and the Tcl binding, three-gram FTS5 indexes, typed numbered parameters, opt-in safeguards on each connection, and verified create-only backup under contention. Compare default connection behavior with baseline fixtures. Review build-wide SQLite options separately from opt-in settings. Immediately follow full SQL with static Graphviz, Expat and a Tk diagram with named ports. Pin sources and notices and measure packaged size against the matching SQL build. The compact offline reference can follow once FTS5 is available. |
| **5. Desktop and files (30.6, 30.6b)** | Build browser session control on the tested process and window lifetime behavior. Cover external launch, session reattachment, cancelling a pending navigation, window switching, Start menu/Store discovery, Explorer drops and opening associated documents. Add per-user storage, confirmed saves, cloud-aware listings and reads, encoding detection and seed-zero XXH3-64. Test browser control with a local page and the file operations with the failure and concurrency cases in the roadmap. |
| **6. Networking and workers (30.7–30.8)** | Deliver the loopback HTTP server and bounded, cancellable streaming client. Test an indefinitely open response, slow consumers, disconnect and restart. Add adapter details and source-bound ping. Qualify UDP before the NTS client. Use a controlled time server and known credentials for valid and invalid authentication, replay and timeout cases. Reusable workers must retain deadlines, cleanup and their archive generation across an update. |
| **7. Audio and graphics** | Prove PCM output and MP3, AAC and HE-AAC decoding with local fixtures. Then join HTTP, playlist refresh, MPEG-TS extraction, decoding and playback into one cancellable HLS test. Exercise Direct2D and Direct3D 11 on Tk widgets through resize, device loss and recreation. Use pixel readback or a reference signal where machines can check the result. Confirm audio, rendering and focus on a real desktop. |
| **8. Application qualification and release (30.10)** | Run the runtime regressions, relocated packaged examples and the porting suite against the release candidate. Use the signed candidate for the managed desktop, proxy, sign-in and live-share update tests. Record which application-specific checks passed, remained unavailable or exposed a runtime defect. Resolve runtime defects against their smallest fixture and repeat their dependent lanes. Follow the sign-off sequence below. |

### First engineering tasks

#### Additional prerequisites agreed on 2026-11-26

| Deliverable | Evidence required before signing |
| --- | --- |
| SQLite contracts on the open connection | Prepare statements without stepping them. Check tails, parameter slots, column metadata and SQLite's flags. Prove the five storage classes survive result retrieval, including NULL, empty text and empty BLOB. Verify read-only state and anonymous binding on the actual handle. |
| Tcl-only application port | Run the application's migration, archive, child, model and host identity tests on its private branch. Exercise the packaged application without its own native extension. Run the original ELS tests separately and retain their deployment assertions. Keep application data and private fixtures local. |
| Agent-facing host commands | Exercise script, manifest and archive checks with valid and invalid inputs. Confirm checking never evaluates the entry. Query the installed build's command and package contract from the shell and verify explicitly requested environment probes. |
| Offline lookup and executable recipes | Resolve exact command spellings to their manifest section. Run a generated worker, headless child, archive and verified backup from examples retrieved from a relocated executable. |
| Live test progress | Verify timestamped start and finish records for gate steps and application test cases, including failures, skips and elapsed times where applicable. Preserve console diagnostics. |

Freeze the resulting source and run the full Windows gate and independent
clean builds again. Compare the complete unsigned executable hashes across
the build PC and hosted Windows before owner signing and attended validation.

1. **Control the implicit linker input.** At the same epoch (`1795616467`)
   the PC's unsigned 22 executable started with SHA-256 `5f763b71` and the
   hosted executable with `663fcff1`. A local control replay reproduced
   the first hash. Changing only MSYS2's `default-manifest.o` reproduced
   the second. The machines used package revisions `6.4-4` and
   `20260815-1`. Pin and verify the actual object/package in
   `tools/dependencies.lock.json`, bootstrap, build identity and Windows
   CI, or explicitly supply a project-owned manifest and prove the implicit
   object is excluded. Inspect the linked PE manifest and VERSIONINFO,
   deliberately exercise a mismatched input, and compare cold builds
   across both hosts. Repeat after the detached-console manifest lands.
   [Hosted baseline run](https://github.com/anafalanx/machteld/actions/runs/45636999191)
2. **Prepare fixtures and facilities during foundation work.** Inventory
   exact versions, licenses, build flags, patches, notices and hashes for
   all new shipped libraries and media fixtures. Check which decoders are
   present on each Windows target and how the runtime will supply HE-AAC
   where the OS component is missing. Verify a TLS backend that supports
   NTS key export and authenticated packets. Measure executable size,
   startup time and first use against the previous milestone as each major
   dependency lands. Establish access to an
   attended Windows 11 desktop, hardware audio/GPU, controllable cloud
   placeholders, two adapters and a representative managed share. A
   missing facility is an open test obligation. Raise a backend or support
   decision while there is still time to change the implementation.
3. **Make development feedback reliable.** Extend the current main/legacy
   branch jobs to run the fast lane and relevant integration lane on 0.30
   integration changes. Build independent cold candidates at integration
   milestones and at the release freeze. Keep unsigned executables on the
   build PC or inside their hosted job. Share checksums and test receipts.
   The reproducibility check on one hosted runner catches repeat-build
   differences. Compare its receipt with the build PC's for cross-host proof.
4. **Exercise long-lived behavior.** At integration milestones, repeatedly
   open and close browser sessions, cancel and restart streams, retire
   workers and recreate Tk surfaces while work is pending. Record the
   cycle count, random seed where used, peak and post-cleanup handle counts
   and memory. Keep the first failing trace and turn it into a repeatable
   regression. Run these longer cases outside the per-change fast lane.

### Test cadence and evidence

| When and where | Evidence required |
| --- | --- |
| **Each implementation slice, build PC** | Run the fast gate and the affected groups. Include valid, invalid and boundary inputs, repeated open/use/close, cancellation during work, competing callers where relevant, and failure after partial completion. For Windows handles, threads and callbacks, exercise interpreter shutdown and measure resource counts before and after repeated cycles. Measure queue bounds, cancellation latency and Tk event delivery against limits written into the feature contract. |
| **At integration, build PC and hosted Windows Server 2025 x64** | Run all five gate groups: fast, integration, packaging, native-validation and reference-generator. Run both the standalone `wrap` checks and the legacy 0.21 compatibility checks. Package synthetic examples with the candidate and run them after relocation without the source tree. Exercise read-only assets and external writable state, damaged archives, version boundaries and archive replacement while old workers run. Probe instrumentation with positive/negative controls and retain actual coverage limits. [Native validation](docs/native-validation.md) |
| **Feature-specific oracles and load** | Compare XXH3-64 with stored reference values, PDF and archive outputs by bytes, SQL against known rows and independent integrity checks, HTTP/UDP against controlled peers, media against known duration and signal, and rendered frames by pixel readback. Exercise the 100,000-entry directory and record game frame pacing against 60 Hz. Capture scenario, sample size, latency distribution, peak memory and handles alongside hardware/driver details. Compare with the same fixture and baseline before accepting a regression. |
| **Desktop and device qualification** | Automate repeatable GUI cases on an isolated desktop. Record attended checks on supported x64 Windows 11 25H2 and the supported Windows Server 2025 configuration, distinguishing actual device coverage from the hosted runner. Exercise two-adapter selection, a placeholder made online-only after listing, a real Explorer drop, default viewer, foreground selection and browser sign-in/resume. Verify audible output and real GPU rendering. Record software rendering and unavailable-device behavior separately. |
| **Release candidate and deployment** | Use exact release-source and artifact hashes. Test the compact reference offline for command discovery and bounded retrieval. Compare two default app launches, an in-use archive update, managed proxy and SMB permissions, old/new sessions and recovery to the previous runtime/archive pair. Verify a clean desktop can launch using the runtime, app archive and documented Windows prerequisites. Use a signed copy on machines outside the build PC and hosted CI. |

Existing gate entry points from the repository root are shown below. The
0.30 work adds or replaces fixtures behind these lanes. The development
command tests an already built candidate. Supply `--msys` or `MSYS2_ROOT`
as described in the build guide. Use `--interactive-gui`, `--interactive-pty`
and `--public-tls` in the environments that can exercise them.

```powershell
& .\dist\0.21\machteld.exe tools\gate.tcl --group fast --group integration --runtime out/dev/machteld.exe
& .\dist\0.21\machteld.exe tools\gate.tcl --msys C:\dev\.z\r\msys2
& .\dist\0.21\machteld.exe tools\gate.tcl --skip-build --runtime $signedCandidate
```

Set `$signedCandidate` to the owner's signed release copy for the last
command. For each gate record the commit, driver/candidate SHA-256, lock
and input identities, epoch, OS build and options, expected and actual
result, and diagnostic or receipt location. Distinguish pass, fail and
unavailable. A skipped mandatory test stays open. A fix after a freeze
starts a new candidate with fresh reproducibility and acceptance evidence.

### Signing, publication and recovery

1. Freeze the release commit with public version 30, Windows file version
   `30.0.0.0` and the prerelease flag clear. From independent clean
   checkouts and fresh dependency caches, set `SOURCE_DATE_EPOCH` to the
   same commit timestamp and compare the **complete unsigned SHA-256**
   across the build PC and hosted CI. Compare incremental output separately,
   accounting for its development-only build record. Archive test receipts,
   source/lock hashes and any approved external prerequisites.
2. After the unsigned gate passes, the owner signs a copy on the build PC.
   Verify the Authenticode signer, the signed executable's version, payload
   and SHA-256. Run the full gate with `--skip-build --runtime` on **those
   signed bytes**. Use that same hash for the second-PC, attended and
   managed-share qualification. A signature changes the executable hash.
   Record both unsigned and signed identities.
3. The owner authorizes publication after reviewing the required receipts.
   Tag the tested release commit, publish the verified signed bytes and
   checksum, and publish the 0.21 upgrade and archive migration instructions.
   Retain the prior signed release and last known-good app archive. Exercise
   restore using a copy of external app data before approving a deployment
   that changes its schema. Move the driver to verified signed 0.30 in a
   separate change and run the gate again using the newly pinned driver.
