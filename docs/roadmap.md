---
type: roadmap
title: Roadmap
description: Direct delivery from signed 0.21 to 0.30, the unsigned 22 baseline, capability ownership and acceptance.
tags: [machteld, roadmap, windows]
---

# Roadmap

## 22 — Unsigned development baseline

**The next public release is 0.30, directly after signed 0.21.** On
2026-11-25 the owner closed 0.22 as an unsigned development milestone.
The reconciled Beta 1 work supplies the starting point for 0.30.
Applications can run as Tcl scripts, packaged archives or wrapped executables.
The runtime includes supervised Tcl jobs, the upstream SQLite binding,
same-version archive workers, atomic file publication and process-owned
locks. The desktop changes cover metadata-only path inspection, quiet workers,
attended child windows and process-scoped clipboard ownership. The beta also
corrected Tcl control flow through `scope`. [Beta 1 scope and release checklist](https://github.com/anafalanx/machteld/blob/e0db215ede968d3255415613d86c66abda210249/docs/releases/0.22-beta.1.md)

The current source and Tcl package report `22`. The first runtime feature
change for 0.30 advances both to `30`. For the baseline, the header declares `"22"`,
the prelude declares `22`, and the fixed Windows file version is `22.0.0.0`.
A Tcl program can request `package require machteld 22-` to accept later
versions, or `package require machteld 22-30` to require review before it
runs on 0.30. Tcl excludes the upper bound. Signed 0.21 drives builds and
tests through acceptance of the signed 0.30 copy. Identify baseline artifacts by their
hashes, verification receipts, `manifest`, and embedded reference.

22 begins as the 0.22 candidate (commit 8bcc1ec), the stabilization of
2026-09-30 to 2026-10-02, which was never released. Its completed steps 1
through 11 include:

- Explicit build/input identities, content-checked incremental caches, and
  test groups. The candidate's separate reference conversion caches are not
  in 22, whose Tcl build reuses a whole reference generation by content.
- Bounded worker frames, batches, and callbacks; one pool attempt by default;
  explicit replay-safe retries, cancellation/cleanup, and timeout contracts.
- A responsive project-inspector example with application-owned worker roles,
  model tests, and separately recorded earlier GUI acceptance.
- Optional wrapped documentation, explicit application payload manifests and
  no-write previews, and an adjacent DLL deployment example with a
  license/hash inventory.
- Native ownership, strict UTF-8/JSON, path-rejection, and boundary fixes;
  repeatable analyzer, adversarial, lifecycle, and scaling checks with stated
  instrumentation gaps. See [native validation](native-validation.md).
- Reconciled guides and command contracts, runnable README checks, and a
  context-aware version gate that allows explicitly marked history.

The release build, dependency bootstrap, reference generator, development
loop and release gate are Tcl programs. Hosted Windows CI can invoke those
tools and exercise the candidate within its verification job.

Version 22 keeps the explicit wrap inventory (`--manifest`), preview
(`--plan`) and optional custom Windows metadata and icons for console and GUI
wrappers. A wrapper without a custom identity uses the host's resources.

Evidence and remaining limits of the stabilization are recorded in
`tools/stabilization.json` in the source checkout; exact artifact receipts live
in ignored `out/` files. Local stabilization ran on Windows 11 Pro x64 build
26200, not every contracted Windows target. Tests do not establish a sandbox,
full sanitizer coverage, or unbounded concurrency. The store remains narrow,
several APIs remain synchronous, and native extensions still need manual
deployment.

**Reconciled baseline evidence.** At `eccba70` the build PC passed 67 steps
and two local cold builds matched. Hosted Windows Server 2025 passed 72
steps and its two builds matched each other. At the same commit timestamp,
the PC and hosted binaries still differed. Substituting just the hosted
MSYS2 `default-manifest.o` in a local replay reproduced the hosted SHA-256.
The first build task for 0.30 is to control that link input and demonstrate
whole-executable equality on both hosts. [Hosted verification](https://github.com/anafalanx/machteld/actions/runs/45636999191)

The build PC and hosted CI may run unsigned builds. Executables produced in
CI stay in the job and expire with it. Other machines use signed releases.
The owner signs a copy on the build PC and authorizes publication after the
gate passes on the signed bytes.

## Delivery order

The target is one signed `machteld.exe` that runs Tcl scripts, creates
application-only `.machteld` archives with `pack`, and runs those archives.
The milestone numbers below identify work items. The first implementation
in release 0.30 is the foreign-function interface, numbered 30.9.

### Start from signed 0.21 and the reconciled source

1. **Capture compatibility and build evidence (30.0–30.1).** Use signed
   0.21 as the driver and public upgrade source. Use `eccba70` as the
   source baseline for archives, jobs, SQL and desktop behavior. Record the
   porting application's results on 0.21 with its existing extension and
   retain synthetic reproductions of runtime gaps. Carry open regressions
   from the stabilization ledger into the relevant 0.30 work items.
2. **Close the build mismatch and define the contracts.** Lock the actual
   linked manifest input, capture its hash, and compare fresh build-PC and
   hosted results from the same commit and epoch. Before implementing a
   feature, specify its Tcl inputs, binary/text handling, errors, limits,
   ownership, cancellation and fixtures. Keep reproducibility and feature
   acceptance as separate checks throughout the release.
3. **Qualify 0.30 directly.** Run the runtime gate and packaged examples
   on the candidate. Exercise application-owned profile migrations, restore,
   updates and managed sign-in in the porting project's environment. Before
   publication, verify the exact signed 0.30 executable on the supported
   Windows targets and the signed desktop/share workflow. The owner decides
   when to publish. The repository's `plan-machteld22.md` gives the
   implementation and release gates.

### What the application ports established on 0.22

Two existing Tcl/Tk applications passed their own self-tests as packaged
GUI executables on the unsigned candidate at `eccba70`. The game exercised
its rules and rendered a frame. The document generator rendered its form
and produced the same PDF bytes twice. Both used a private desktop.
Attended keyboard, window and file-viewer checks remain open.

The timer application parsed four shipped sequences, stored them using its
own Tcl code, and reopened the database read-only with a successful integrity
check. A file catalog's current schema also loaded. The larger desktop
application passed 85 selected offline model tests using a test-only Tcl
adapter. All five archive migrations ran on a synthetic database. Its
numbered SQL parameters needed adaptation to Tcl bindings, and a backup
probe overwrote an existing destination. A launcher and a radio
directory both use FTS5 trigram indexes. Creating such an index on the
candidate failed with `no such module: fts5`.

Use these cases for the 0.30 porting work. For full-text search (30.5),
exercise the consumers' external-content trigram indexes through the
upstream Tcl binding. Verify that insert, update and delete keep search
results correct and that a populated catalog reopens in a packaged app.

### Which capabilities ship in 0.30

The completed ownership poll assigns 25 capabilities to `machteld.exe`.
Applications supply system-wide keyboard shortcuts. A capability can be
implemented in Tcl and still ship inside the runtime. The contracts below
describe planned behavior and the checks for accepting it.

#### Desktop, browser and process integration

**Browser control ships with Machteld.** Include browser-session and page
control in `machteld.exe` so any Tcl application can open an installed
Edge or Chromium browser with a chosen profile, navigate to a page and
detect when it is ready. Each application owns its sign-in workflow and
site-specific actions.

Use a local test page and a disposable browser profile to exercise launch,
navigation and orderly shutdown. Separately, check on
an attended desktop that the user can complete sign-in and the application
can resume its work in the same session.

**Initial child window visibility ships with Machteld.** Let the caller
request a visible or hidden first window when launching a supervised GUI
child. Windows passes this as a startup hint and the child can override
it. Exercise both settings with a GUI fixture that follows the hint.
Verify that supervision and exit reporting work in both cases.

**Desktop-wide window listing and activation ship with Machteld.** Let a
Tcl application list open windows on the user's desktop, including windows
opened by unrelated programs, and request activation of a selected window.
The application chooses what to display and how to search it. Test a window
that closes after listing and two windows with the same title. Verify in
an attended session which window actually receives focus.

**Windows application discovery ships with Machteld.** Let Tcl applications
list Start menu shortcuts and Microsoft Store apps with their display names,
icons and launch targets. Each application owns its search, ranking and
presentation. Verify that a shortcut and a Store app appear while closed
and that each returned target opens the intended application.

**Explorer file drops ship with Machteld.** Let a Tcl application register a
Tk widget as a drop target and receive the list of file paths dropped on it
from Windows Explorer. The application decides how to handle those paths.
Verify an attended multi-file drop using names with spaces and non-ASCII
characters. Check that destroying the target removes its registration.

**Opening a document in its associated application ships with Machteld.**
Let Tcl pass a local file path to the Windows shell to open it with the
user's chosen application. Report a missing file or an unavailable
association to the caller. Verify on an attended desktop that the selected
viewer opens the intended document, including a path with spaces.

**Applications ship system-wide keyboard shortcuts.** Each application that
needs a shortcut while another window has focus supplies its Windows
registration, conflict reporting, delivery to the Tcl event loop and cleanup.
The application chooses the key combination and the action it triggers.

#### SQLite, files and text

**Numbered SQLite parameters ship with Machteld (30.5).** Include a helper
in `machteld.exe` that binds typed Tcl values to numbered SQL parameters
such as `?1` and `?2` using the existing SQLite engine. Applications can
keep their SQL. Test repeated and out-of-order parameters, text, integers,
blobs and explicit SQL NULL. Report a missing value as an error.

**An opt-in SQLite connection profile ships with Machteld (30.5).** Let an
application request foreign-key enforcement and SQLite defensive mode when
opening a connection. Apply and verify the settings before returning the
connection. Report an error if a requested safeguard cannot take effect.
Test a foreground connection and a separately opened worker connection to
the same database, including an insert that violates a foreign key.

**Verified SQLite backups ship with Machteld (30.5).** Provide a backup
operation that reopens the copy read-only, runs SQLite's integrity check and
publishes the verified copy only if the destination is still absent. An
existing destination must survive byte-for-byte, including when another
writer creates it during the backup. Test a successful backup, an existing
destination, competing writers and a failed verification. Applications choose
when to back up, how long to retain copies and what to restore.

**Confirmed file saves ship with Machteld.** Offer an opt-in save operation
that atomically replaces the destination and then asks Windows to flush the
final file to storage. Report which stage completed so an application can
distinguish a failed replacement from a completed replacement whose flush
failed. Applications choose how to present the result or offer a retry.
Exercise both failures and a successful save. Check the bytes at the
destination and the result returned to Tcl in each case.

**Bulk directory listings ship with Machteld.** Provide a Tcl operation
that enumerates one Windows directory and returns each entry's name, size,
modification time and Windows attributes in a single pass. Include hidden,
junction, pinned and online-only entries. Listing a cloud placeholder must
leave its contents online. Applications choose what to display or index.
Measure a 100,000-entry directory and verify the reported attributes on
fixtures with Unicode names, a junction and cloud placeholders.

**Local-only file reads ship with Machteld.** Provide an opt-in read mode
that reads locally available contents and reports an online-only file to Tcl
without requesting a download. Apply this behavior when opening and reading
the file, even if an earlier directory listing showed it as local. Let the
application decide whether to skip the file or request it through a normal
read. Verify local bytes, an online-only placeholder and a file made
online-only between listing and reading. Distinguish unavailable cloud
contents from an access error.

**Text-encoding detection ships with Machteld.** Let Tcl applications pass
file bytes to a detector and receive a likely encoding and a confidence
estimate, or an explicit result when the detector finds no match. The
application chooses how to decode the bytes and when to ask the user.
Test representative UTF-8 and legacy-encoded text alongside ambiguous
input, and verify that detection preserves the original bytes.

**XXH3-64 ships with Machteld.** Add it to the existing hash commands for
bytes, files and incremental input. Match the seed-zero XXH3-64 values in
existing file catalogs. Test known values and compare a file hashed in one
pass with the same bytes supplied in uneven chunks. Verify that an unchanged
file still matches its previously stored checksum.

#### Networking

**HTTP streaming ships with Machteld (30.7).** Let Tcl applications
consume binary response chunks as they arrive and cancel an open
transfer. Bound buffering when the consumer is slower than the sender.
Test with a local server that sends a first chunk and holds the response
open. Verify delivery before the response ends, prompt cancellation while
waiting for more bytes, and bounded memory with a slow reader.

**A local HTTP server ships with Machteld.** Let a Tcl application listen
on the loopback interface and handle HTTP requests from a browser on the
same PC. The application supplies its pages, routes and request handlers.
Test serving a local page and a changing JSON response while Tk stays
responsive. Verify the listener's bound address and that closing the server
releases its port.

**Windows Wi-Fi connection details ship with Machteld.** Let Tcl applications
query each wireless adapter for its connected network name, signal quality
and negotiated link speed. Report when an adapter is disconnected or Windows
permissions restrict a field. Test those cases and verify adapter identity
and reported values on a connected Windows machine.

**Adapter-specific ping ships with Machteld.** Let a Tcl application supply
the source IPv4 address and destination for an ICMP echo request. Return
the measured round-trip time, a timeout or a Windows error. On a machine
with two active adapters, verify that the echo uses the selected source.

**UDP sockets ship with Machteld.** Let a Tcl application send and receive
individual datagrams and receive a readable event through the Tcl event
loop. Return the sender's address and port with each datagram. Applications
define their own protocols. Test a local exchange of distinct binary
datagrams, Tk responsiveness while waiting for a reply, and closing a
socket with a read notification pending.

**Authenticated network time ships with Machteld.** Provide a Network Time
Security (NTS) client that obtains an authenticated time sample from a
server chosen by the Tcl application. Verify key exchange and a valid
reply against a controlled time server. Check that a failed authentication
returns an error and yields no accepted time sample. Applications choose
their servers, compare samples and decide what time and uncertainty to
display.

#### Audio and graphics

**Windows audio output ships with Machteld.** Let Tcl applications send
uncompressed PCM samples to the Windows audio device for short effects or
continuous playback. Verify that a short effect finishes, that successive
buffers play in order while Tk stays responsive, and that stopping a stream
releases the device for the next playback. Confirm audible output in an
attended session.

**MP3 and AAC decoding ship with Machteld.** Expose a Tcl interface that
accepts compressed audio and returns PCM samples with their sample rate and
channel count. Support MP3, AAC and HE-AAC and allow the samples to feed
the runtime's audio output. Test each format with a local fixture split
across input chunks. Check the decoded duration and signal against known
audio and verify error reporting for malformed input.

**HLS audio playlist support ships with Machteld.** An application supplies
a playlist URL. The runtime follows playlist updates, fetches new segments
in order and extracts compressed audio from MPEG-TS for decoding. Test with
a local live playlist whose successive versions overlap. Verify that each
segment plays once in order and that stopping playback cancels further
playlist and segment requests.

**Hardware-accelerated 2D drawing ships with Machteld.** Expose a Direct2D
drawing surface in a Tk window that Tcl applications can use for their own
graphics. Exercise it with a clock face and a moving sprite. Check resizing,
display scaling and input responsiveness, and measure frame pacing against
the game's 60 Hz target on the test machine.

**Direct3D 11 rendering ships with Machteld.** Provide a Tk surface that
lets Tcl applications draw with shaders and read back rendered pixels.
Use a rotating triangle as the acceptance fixture. Read a background pixel
and a pixel inside the triangle, repeat after resizing, and record whether
the test used a hardware device or the Windows software renderer.

### Build the shared application runtime

1. **Windows DLL calls (30.9).** Add the optional, statically linked `cffi`
   package for synchronous calls. Document ownership, text encoding and DLL
   lookup. Test an allowed call, a refused load, and handling of a failing
   call in a worker.
2. **Supervised processes (30.2–30.3).** Build on `machteld::job`,
   `child start -console none` and `child present` in 0.22. Add native
   child-completion notifications through the Tcl event loop and graceful
   shutdown. Add the initial window visibility option at launch. Test one
   completion notification per child while a Tk window remains responsive.
   Retain the tests for window handoff within a job.
3. **One executable for development and delivery (30.4a, 30.4).** Keep
   direct Tcl entry. Embed `consoleAllocationPolicy=detached` in the Windows
   console-subsystem manifest. Extend the existing `pack` and archive launch
   with an explicit project inventory and verify it before executing
   application code.
   Remove `wrap`, its Tcl and CLI entries, and both executable templates.
   Build an example with only the runtime, project manifest, script and asset.
   Run it in another directory containing only the runtime and archive.
   Reject a damaged archive and attempts to write a mounted asset. Verify
   replacement of the runtime and archive on a live network share. Test a
   shortcut without a console flash on the development PC and a second PC
   running the signed build. Test terminal input, redirection, waiting and
   exit status. The archive options and manifest syntax are
   design work within this milestone.
4. **SQLite (30.5).** Enable FTS5 in the same SQLite engine used by the
   Tcl `sqlite3` package and the key/value `store` in 0.22. Deliver the
   numbered-parameter helper, opt-in connection profile and verified
   create-only backups. Test both default and opt-in connections, typed
   round trips, transactions and read-only access.
   Exercise joins and atomic imports in a packaged example with an external
   writable database. The application owns its schema upgrades and restore
   policy.
5. **Graphviz for Tk, immediately after SQL (30.5a).** Embed the static
   `dot` engine, orthogonal routing, HTML-like table labels and xdot drawing
   instructions. Lay out a graph with named table ports, render it on a Tk
   canvas and verify that selection still works. Measure the size against
   the matching full-SQL executable.
6. **Desktop and files (30.6, 30.6b).** Add per-user storage and finish the
   process controls. Deliver browser control, window switching, installed-app
   discovery, Explorer file drops and opening a document with its associated
   app. Use the existing file and hash commands as the starting point for
   confirmed saves, bulk listings, local-only reads and XXH3-64. Add
   encoding detection. Exercise competing writers and check file handling
   with a cloud placeholder. Verify user-visible desktop behavior in an
   attended session.
7. **Networking and workers (30.7, 30.8).** Add cancellable HTTP streaming,
   a loopback HTTP server, Wi-Fi connection details and adapter-specific
   ping. Bring up UDP before qualifying the authenticated network time
   client. Verify the application's authenticated HTTP request through its
   actual proxy. Exercise Tk responsiveness and cancellation. Reusable
   archive workers must preserve the `app launch` guarantee that an existing
   session keeps its archive generation after an update. Reject a mismatched
   generation before executing its code.
8. **Audio and graphics.** Exercise PCM output and the MP3 and AAC decoders
   with local fixtures, then run a complete HLS stream through HTTP, decoding
   and playback. Test the Direct2D and Direct3D 11 Tk surfaces on a supported
   Windows machine. The “Audio and graphics” section gives the playback and
   rendering checks for each surface and format.
9. **Qualify a real application (30.10).** Run its acceptance suite against
   the shared runtime and packaged sources. Exercise the signed runtime and
   archive from a user's desktop and share, including an application update
   while an older session is open. Verify that the application builds and
   runs with the shared runtime and its application files alone. Each
   remaining application-specific native dependency needs the owner's
   approval before the migration is complete.
   The release gate includes clean reconstruction and checks on the signed
   bytes before publication.

### Compact offline reference for agents

Ship an agent-facing reference in the shared executable. Keep a short
bootstrap, stable page and section IDs, command aliases, signatures,
arguments, results, errors, limits and runnable examples. Preserve the
version-specific Tcl/Tk knowledge and applicable notices. An agent should
be able to find a command offline and fetch one relevant section as bounded
JSON. Use SQLite FTS5 for full-text search. Retire `search.dict`, its custom
scorer, and the separate `catalog.dict` and `catalog.json` files. IDs,
aliases, ordered sections and corpus identity remain ordinary database
records. The build generates the FTS5 index once. Open the read-only database
on the first docs query.

The proposed text format is Markdown alone. Store each section once and point
FTS5 at that text. Maintain Machteld's original Markdown and the reference
generator in Git. For Tcl/Tk, keep the versioned source archives available
in the dependency cache and their SHA-256 hashes in the lockfile. The build
uses their original manuals and pinned converter to generate HTML and then
Markdown. A clean build with the cached inputs must regenerate the reference
database offline. Omit the generated HTML, its navigation pages and
stylesheets, and the original upstream manpage files from the compact
executable. Carry over any file-specific attribution found only in those
sources. The catalog used to plan the conversion had 468 Markdown pages and
three license records served as text. Agents must still be able to query
exact IDs and export Markdown.
Version the removal of HTML and raw-source retrieval and the change to the
extracted file layout. Keep the machine-readable schema and integrity checks.

Measure the final executable against a matching full-SQL build, along with
first-query time and peak memory. Test ambiguous aliases, punctuation in
options, short terms, error codes, natural-language searches and bounded
JSON. Verify that every retained page and section resolves and that the
corpus matches the runtime. Graphviz stays immediately after full SQL.

## Historical record

The sections below retain earlier decisions, defects, and measurements at their
original versions. They are not current capability claims or fresh benchmark
results. In particular, all engine/Lua functionality described in the early
sections was removed. Local tag dates below use Europe/Brussels and are not
claims about GitHub publication timestamps.

<!-- machteld-version-history: begin -->

## 0.11.0 baseline

- Direct opted-in Tcl entry and package `machteld 0.11.0`.
- Process control: supervised `run`, `child`, `wait`, and `scope`; independent
  `detach`.
- ConPTY interaction with `pty expect` and `pty strip`.
- Filesystem observation and traversal: `watch`, `dirs`, `links`, and `canon`.
- Machine processes, WinHTTP, JSON, CNG hashes/random, and static SQLite store.
- Program support: `cli`, `log`, `worker`, `pool`, and `pmap`.
- Explicit native/Tcl manifest metadata and complete embedded Machteld, Tcl 9,
  and Tk 9 reference with agent-oriented query, verification, and extraction.
- Atomic console/GUI `wrap` with hidden assets and the complete runtime.

The next three sections record the former 0.12.0-0.14.0 compute subsystem for
release history. The complete subsystem was removed in 0.20 and is not part of
the current runtime or reference.

## 0.12.0 — the engine

The release moves all Lua out of the host process and replaces the 0.11.0
`macht` grammar with an engine: the executable in engine mode, commanded by
the `macht` verb family over a language-neutral wire, under the then-current
engine contract. Committed, in build order; each phase ends with every
test lane green and the tree never holds a gap between a removal and its
replacement:

1. **Contract first.** The engine page, and the engine sections of the
   contract, direction, creed, architecture, palette, and parallel guides
   (this phase).
2. **Engine mode in the executable.** A host-only entry that initializes no
   Tcl, runs the frame loop, and hosts the metered-state pool with shard
   threads - the machinery proven in the reken B- and E-spikes, transplanted.
3. **The `macht` family in the host**, built on `child -channels`, `scope`,
   and the job machinery: lifecycle, load/def/run/free/stats, a lazy default
   engine, `-engine` addressing, `-threads`, kernels cached by source hash.
   The private `LuaCell` leaves the host.
4. **The removal.** Grammar, emitter, Tcl arm, router, and oracle deleted from
   the prelude; the test lane rewritten engine-shaped, including the kill of a
   kernel inside one C call; the `macht` reference page rewritten.
5. **Libraries in the engine.** LPeg and lua-cjson as pinned lock entries, the
   built-in `utf8` opened; kernels parse real data from day one.
6. **The loader.** `macht load -csv|-lines`: a correct single-thread C parser
   into typed pools, hostile-fixture-tested at build time.
7. **Version, gates, ship.** The 0.12.0 sweep, a live demo of residency and
   the kill, and the conformance suite run against the built-in engine.

All seven phases landed; 0.13.0 and 0.14.0 extend that baseline. A program
written against 0.11.0's entry line still starts: `package require
machteld 0.11.0` is satisfied by 0.12.0 under Tcl's version rules, though
the 0.11.0 macht grammar it may have used is gone.

Deliberately not in 0.12.0: a resident engine daemon shared across runs;
bulk transfer of large Tcl-born data (road 1's ceiling applies; files enter by
path); parallel ingestion (the sharded, schema-specialized loader is its own
measured project); and any network. Each is named in the engine contract's
closing section so that its absence is a promise, not an oversight.

## 0.13.0 — the primitive palette

The `col` library: precompiled column primitives in the cell, reaching
the pool's native memory at measured memory-bandwidth speed, under the
then-current engine contract. Filters
over integer and float columns with IEEE law; exact chunked integer sums
and the normative row-striped float tree; the fused one-pass
`sumwhere`; NaN-skipping min/max; the selection algebra. Everything is
plain autovectorized C: hand intrinsics were raced pair-by-pair against
the compiler and earned residence nowhere. The capability is
CPUID-gated and negotiated in `hello`.

The admission story, kept visible: the prior roadmap conditioned
primitives on "a re-profile showing kernels dominate the pipeline"; the
owner waived that gate on 2026-08-22, making primitives the release
headline and moving the evidence into registered predictions. The
predictions were then graded in the open (plan-machteld-013 in the z
estate): sums at the memory wall; the fused form 13-17x over the pinned
Lua loop, admitted after an honestly recorded miss of the composed
form; one `col` thread 3.3x faster than the twelve-shard Lua path, so
arithmetic no longer shards; the 0.12.0 demo question from 2.9 ms to
0.083 ms engine-side. One 0.12.0 defect (a first-touch sharded view
race) was found by the plan's review panel and fixed ahead of the
benches. A 0.12.0 entry line still starts under Tcl's version rules.

## 0.14.0 — the dictionary and the GUI verbs

The release that made big files interactive, proven by a spike GUI that
filters a 5 GB, 25-million-row csv at typing speed (keystroke-to-repaint
median under 100 ms). Its parts, each under "The col library" and road 2
of the then-current engine contract:

- **Dictionary-encoded string columns.** Every `s` column dictionaries
  at load; string `filter` (`eq`/`ne`/`match`, byte-exact, `*`-only
  glob), a string predicate arm for `sumwhere`, and `distinct`/`values`
  answer from the dictionary. The cardinality escape is rows-relative -
  `min(1,048,576, max(65,536, rows/8))` - ruled from a measured sweep
  (n/k = 8 to 250: the dictionary won everywhere the rule admits it),
  and the mode is visible per pool in `stats`.
- **Lazy views.** A column materializes on first touch, under a
  liveness law that refuses a freed pool by name - so col-only kernels
  run over pools far larger than the state cap, which is what makes the
  5 GB pool usable at all.
- **The GUI verbs.** `col.rows` (the bounded page), `col.groupcount` /
  `col.groupsum` (the chart verbs), `col.topn` (order-by, ties
  deterministic). Filter, count, group, order, page - one kernel, one
  round trip.
- **The walls, closed.** From the endurance spike before the strings
  work: kernel-table LRU eviction, the bounded view cache, and the
  stats occupancy gauges - a long-lived engine no longer has a cliff to
  fall off, and the gauges show the water line.

The admission story, kept visible (plan-machteld-014 in the z estate):
every number was a registered prediction graded in the open; three
adversarial review panels folded fourteen findings before code was
written (among them a liveness law, a fixture whose bar sat above an
arithmetic ceiling, and a debounce bypass); the honestly recorded
misses stand unre-banded - the worst-case sorted header click (~1 s,
banked as evidence for a smarter selection pass), one wall bar by 4%,
one absolute eq cost at the extreme cardinality. Two implementation
defects were found by their own benches and fixed inside the registered
designs (a branchy dictionary sweep; a needless per-row group buffer).
A 0.13.0 entry line still starts under Tcl's version rules.

## 0.15.0 — first-class JSON (cut 2026-08-30)

**First-class JSON** (plan-machteld-015 in the z estate; driven by
MACHTELD-WEBSOCKET-CDP-HANDOFF.md at the repository root, real field
work): the palette's json reader stands on a vendored yyjson 0.12.0
core with the plain mode byte-faithful and its emitter deliberately
unchanged; a TYPED mode gives real JSON identity - document-backed
opaque values, an all-leaves-explicit constructor law, a fail-closed
number grammar gate, strict decode, `json value/type/unwrap/get/
exists` - so machteld can finally say `true`; `http -redirect none`
stops authenticated requests at the first 3xx, proven by a two-server
canary; the bounded-delivery covenant is contract doctrine; and a
porting exercise found and fixed a three-release-old wire bug
(structured `macht run` args arrived stringified).

Also in 0.15.0: **the pty redirected-parent fix** - a pty child's
stdio now binds to the ConPTY even when the parent's own stdio is a
pipe or file (found by the platform-plan review panel probing this
roadmap's own claims; gated headless by a canary fixture, proven red
then green). This was cut as a clean state; the merge it anticipated was
later withdrawn (see below).

Correction (2026-09-05): this entry originally also claimed that the
generated wrap launcher derived its `package require machteld` pin from
the running runtime's version. It did not; the launcher carried a hardcoded
literal through 0.15.0 and 0.20, kept in step by the release gate's version
trio check. The derivation exists from 0.21 on, and the gate now refuses a
literal.

## 0.15.1 — unreleased documentation checkpoint (2026-09-03)

No runtime change from 0.15.0. The prose corpus had fallen behind the
product: the README still announced 0.14.0, and fourteen pages plus
three reference pages still named 0.14.0 as the current version, because
the release gate enforces the version trio in the header, the prelude
and the wrap launcher and derives every test expectation from
`src/machteld.h` - but prose was never in its remit. Every
current-version claim was advanced to 0.15.1; genuine version history (engine
mode arriving in 0.12.0, the per-release sections above) is left as
written, because renumbering history makes it false.

Also corrected: **the contracted platform floor**. `contract.md` and the
README claimed x64 Windows 10 1809 or newer; the owner amended the floor
on 2026-08-30 to **Windows 11 25H2 (build 26200) and Windows Server 2025
(build 26100)**. Windows 10 and Server 2022/2019 are below it and ARM64
is not a target. ConPTY still sets the technical floor at 1809, so the
binary may start below the contract - it is simply not supported there.
The `pty` page's own 1809 reference is about ConPTY's requirement and
stands unchanged. This checkpoint did not become a 0.15.1 build, public tag,
or release artifact; those steps were skipped when 0.20 became the next target.

## 0.20 — clean Tcl/Tk foundation (released; local tag 2026-09-05)

**The X merge is not happening.** The 2026-08-29 ruling that machteld
and the statically typed X language would become one product is
withdrawn (2026-09-01): X is no longer developed as machteld's language,
and **Tcl is the program form**, first-class and alone. X's design
record lives in its own repository.

The direction is Machteld's viability as a Windows **command and control**
system: commanding and supervising processes, machines, and instruments from
Windows, which is what the palette is already shaped for. Tcl is the sole
program language, Tk is the GUI toolkit, and admitted native work is C or C++.

Version 0.20 is a deliberate subtraction release: engine mode, its wire,
`macht`, Lua, LPeg, lua-cjson, and the engine-bound `col` implementation were
removed together, with no migration surface. It adds no replacement capability;
the clean Tcl/Tk runtime is the baseline for subsequent development.

## 0.21 — consolidation (released; local tag 2026-09-06)

**Same capabilities, cleaner and more robust.** A complete read of the 0.20
tree - every C and Tcl source, every tool, test, and page - looking for
mistakes and for things to consolidate. Nothing is added to the palette and
nothing is removed from it.

Corrected:

- `http post` read its body with `Tcl_GetByteArrayFromObj`, which sends
  U+0080..U+00FF as Latin-1 and returns NULL (length untouched) for any
  string beyond U+00FF; a JSON body with non-ASCII text was mis-encoded or
  read an uninitialized length. `run`/`child start -stdin` wrote the string
  representation, so a bytearray was never binary-safe. Both now follow the
  one byte rule (`Machteld_ValueBytes` in `machteld.h`) that `hash` and
  `store` already used, and the contract states the rule once. The rule
  itself now means real UTF-8: `hash` and `store` had used Tcl's internal
  string bytes, in which U+0000 is the two-byte sequence C0 80, so a string
  containing NUL hashed and stored differently from its UTF-8.
- The pool spoke to its workers over the raw binary channels `child
  -channels` hands over, while `worker serve` spoke strict UTF-8: non-ASCII
  text crossed the wire as Latin-1 mojibake. The channels are now strict
  UTF-8 both ways; a worker reply that is not UTF-8 is a protocol death, and
  `pool submit` refuses an item that cannot encode as plain JSON.
- A worker whose handler returned a value that cannot encode as plain JSON
  (a typed json value) swallowed the encode error and left the request
  unanswered, holding the director until its batch timeout. It now answers
  with `WORKER failed`.
- Strict typed decode checked duplicate members quadratically; a 16 MiB
  object with a few hundred thousand members turned `json decode -typed`
  into minutes of work. Detection is now sort-based past sixteen members.
  `lseq` values (Tcl 9's second list representation) encode as arrays;
  `json exists` requires a path step as documented; iteration temporaries
  use `Tcl_BounceRefCount`.
- `json decode -typed` formatted its duplicate-key error from a pointer into
  the document it had just freed. Unnoticed on small inputs, a crash on a
  large one (found by the new 200k-member test). The message is now built
  before the document is released.
- `watch` converted names leniently, so an unrepresentable name could arrive
  renamed to U+FFFD; it is now counted as dropped, like `dirs`.
- A `child start -channels` whose channel setup failed leaked the stdin
  write handle; `wait -any` tested the done list's string length instead of
  its element count.
- The roadmap's 0.15.0 claim that the wrap launcher derived its version pin
  was false (see the correction above); the derivation now exists.
- The `--machteld-engine` entry test read its exit code from a timed
  `Start-Process` without `-Wait`, which Windows PowerShell 5.1 leaves empty;
  the 0.20 gate was red on that one check in that shell. The test now waits
  on the process (its stdin is an empty file, so nothing can block).

Consolidated:

- One Win32 text boundary, `wintext.h`/`wintext.c`, replaces six private
  copies of the UTF-8/UTF-16 converters (two of them lenient) across proc,
  dirs, http, ps, and the launcher.
- One build description, `tools/buildlib.tcl`, is read by both the hermetic
  release build and the development loop, so a dev object is a release
  object. `-Werror` is on by default (`MACHTELD_WERROR=0` to relax), and the
  SQLite embed compiles with `SQLITE_DQS=0`, `SQLITE_OMIT_DEPRECATED`, and
  `SQLITE_OMIT_SHARED_CACHE`.
- One MSYS2 discovery, `tools/toolchain.ps1`, shared by bootstrap, build, and
  test; `dev.tcl` follows the same order and no longer carries a hardcoded
  estate path. `--enable-threads` is gone from the Tcl/Tk configure lines
  (Tcl 9 is always threaded and warned about the unknown option).
- `tools/check_version.tcl` joined the release gate, checking version-like
  numerals outside the roadmap and refusing a literal launcher pin. Its broad
  numeric matching was not a semantic check and excluded this entire roadmap;
  the current development checker replaces that policy (see above).
- The Tk package registration, the reference corpus check, and the `help`
  banner read the linked library's `TK_PATCH_LEVEL`, recorded by the host as
  `::machteld::tk_patchlevel`, instead of two hand-maintained `9.0.4`
  literals; the Tcl check reads `info patchlevel`.
- Dead assignments in `cli`, `pmap`, and `worker` removed.

Dependency: SQLite moves from 3.51.0 to 3.53.4 (2026-07-24). The span carries
the WAL-reset database corruption fix (3.51.3), the nested-EXISTS incorrect
result fixes (3.51.1, 3.51.2), and four rounds of 3.53.x fixes. The store runs
fixed statements with bound parameters and never enables WAL, so none of the
fixed defects were reachable through it; the bump is hygiene. The amalgamation
is pinned by SHA-256 in the lock; its archive and its `sqlite3.c` were checked
against sqlite.org's published SHA3-256 values before pinning. 3.53.0 changed
SQLite's float-to-text rounding to 17 significant digits; the store never
formats numbers, so nothing observable changes.

<!-- machteld-version-history: end -->

## Candidate studies

- **Console control ownership** remains a candidate for 0.30. A program
  handing its console to a child needs a way to let that child handle
  Ctrl-C. The proposal in `docs/proposals/console-ctrl/` describes
  `console ctrl ignore|default` and a query for the current mode. The
  beta's `child start -console none` suppresses the console for opted-in
  helpers. Milestone 22.4 covers the remaining captured-child behavior
  when the host has no console.
- The timeout selectivity study (cross-industry lineage,
  `study-cross-industry.md` in the z estate).

## Roads examined and not taken (2026-08, the runtime tour)

<!-- machteld-version-history: begin -->

A deliberate discourse arc examined every serious route to a vast library
ecosystem, and the owner ruled for the narrow product: **programs are Tcl; the
author provisions native needs in the box as C/C++ palette commands or Tcl
prelude code; external software is supervised through `run`, `child`, and
`scope`**. Users may bring their own Tcl packages and DLLs in a folder beside a
built tool. Recorded so these are reopened by argument, not by forgetting:

- **External embedded runtimes** - Deno, Bun, Node, Go, Python, QuickJS, wasm,
  and Lua - were examined and retired with their generic protocol and
  conformance machinery. That machinery is removed in 0.20, not left dormant.
- **TinyCC** (compile-on-target) was refused for code-generation quality,
  antivirus posture, and inability to participate honestly in build gates.
- **llama.cpp and DuckDB as machinery**: examined, unruled; the
  assessments (local models as organs-not-brains with
  grammar-constrained JSON; DuckDB as the analytics gap-filler) live
  in the estate ledger for whenever a driving program appears.
- A porting benchmark (Perl's Math::Polygon to Tcl and Lua,
  oracle-exact in ~40 seconds each) priced the doctrine: algorithmic
  needs are ported on demand; only semantic mass ever argued for an
  ecosystem, and no current program needs one.

<!-- machteld-version-history: end -->

## Deferred: the palette gains xml (decided 2026-08-20, deferred 2026-08-22)

<!-- machteld-version-history: begin -->

Solid XML handling, validation included, was decided on 2026-08-20 as a
palette organ beside `json` — runtime capability, not an extensions-covenant
errand — and deferred on 2026-08-22 so the historical 0.12.0 release could stay
focused. The capability remains decided, but no release is assigned. The
deciding programs are the rail-family operations formats
(railML, NeTEx, TAF/TSI, Darwin push data): schema-described XML is the
data plane of long-lived operations environments, and a runtime that
promises "just works for years" must read it in the box.

This is a dated proposal, not an implemented API or current dependency
recommendation. Candidate versions and integration claims below have not been
revalidated for admission. Recorded as constraints, not answers — the route is
design work:

- The leading vendor candidate is tDOM 0.9.7 (C, Tcl 9-ready, bundles
  expat 2.7.3): DOM, XPath, DTD validation, and its own schema engine,
  statically linkable the way SQLite entered, pinned through the
  dependency lock with its license notices verified and carried. A narrower
  expat-based organ is the fallback if tDOM's surface proves too wide for a
  palette contract.
- "Validation" is pinned by name during design: well-formedness always;
  DTD and tDOM's schema engine are on the table; full W3C XML Schema is
  deliberately not claimed — that claim costs Xerces-class machinery the
  covenant refuses. Whatever subset ships is stated exactly, and the rest
  is refused by name, never approximated.
- The usual admission bar applies: a narrow Tcl-shaped contract, structured
  `{MACHTELD XML ...}` failures with depth/size guards the way `json` has
  them, external-entity and all network resolution refused by default (the
  classic XML trap), manifest metadata, and tests on real rail-format
  fixtures plus hostile ones (XXE, entity expansion, depth bombs).

<!-- machteld-version-history: end -->

## Candidate additions

Windows registry, services, event log, network facts, users, host facts, and
selected WMI queries remain candidates. None is built into the current runtime or has
an assigned release. Each needs a concrete program, a narrow Tcl-shaped contract,
structured failures, manifest metadata, and tests on real Windows behavior
before admission.

Earlier extension proposals included automatic dependency classification and
a target-side `--deps` verifier. These remain unimplemented candidates, not
part of the current wrapper contract. The current approach is explicit: select
embedded files with a wrap manifest and maintain a separate adjacent-DLL
deployment inventory, including licenses. See [External libraries](extensions.md)
and the `examples/external-extension` demonstration. No automatic resolver or
dependency discovery is provided; future machinery needs its own admission
decision.

The route forward is a smaller surface whose invariants have survived use, not
a longer list of verbs. New policy layers and bundled applications are out of
scope for the runtime itself.
