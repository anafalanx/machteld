---
type: roadmap
title: Roadmap
description: What Machteld 0.21 contains and how possible additions are ordered.
tags: [machteld, roadmap, windows]
---

# Roadmap

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

## Continuing stabilization before breadth

1. Gate the opt-in parser, direct host, both wrapped hosts, and `EntryCheck`
   against the same entry corpus.
2. Check every manifest command, subcommand, option, result key, and error code
   against behavior, including protocol reply codes.
3. Stress process-tree cleanup, channel closure, ConPTY teardown, worker death,
   pool replacement, SQLite contention, and atomic wrapper failure paths.
4. Keep package versions and the machine-control/data surface identical across
   all produced executables; test the documented distribution-only exceptions.
5. Measure startup, idle memory, and packaging size after the product cut.

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
then green); and the generated wrap launcher now derives its
`package require machteld` pin from the running runtime's version
instead of a hardcoded literal. This was cut as a clean state; the merge it
anticipated was later withdrawn (see below).

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

## 0.20 — clean Tcl/Tk foundation (released 2026-09-04)

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

## 0.21 — the fine comb (in preparation)

No capability is added or removed; the 0.20 surface is combed for defects and
each one is fixed in place, with a regression check where the release gate can
carry one. Fixed:

- **Documentation.** `help` failed with `invalid command name "Page"` on any
  page longer than the default retrieval limit: the continuation marker was a
  command substitution. `docs verify` no longer computes totals it discards.
- **Workers.** The `pool` director never configured UTF-8 on the byte-oriented
  channels `child start -channels` hands it, so non-ASCII text left as `?` and
  returned as mojibake; a worker dying between a reply and its next request
  could raise a background error out of the pool's read callback; the stderr
  cap is one constant; request encoding names its container.
- **JSON.** `encode -list` bypassed the typed-value check at the top level
  (a typed array was re-parsed as Tcl words, and `-plain` could not refuse it);
  a duplicate key in `decode -typed` was reported after the document was freed;
  a repeated key leaked its Tcl key object in plain decode; strict duplicate
  detection was quadratic per object; a NUL inside a string was mis-spelled in
  both directions; a lone surrogate could make a typed handle render as `null`
  (it is now refused by name); `json value array|object` given a typed handle
  destroyed it; a nesting breach in a constructor carried `type` instead of
  `depth`.
- **HTTP.** `post` with a plain string body crashed on a character above
  U+00FF and sent Latin-1 below it; the whole certificate failure family is
  `tls`; a repeated response header leaked its key; a later `-headers` kept the
  earlier dict's Content-Type fact; a connection-handle failure is `oserror`,
  not `notfound`; the usage line matches the manifest.
- **Processes.** `run -stdin` re-encoded a bytearray through its string
  representation, and reported a child that exited before reading its input
  as an I/O failure; `child kill` on a finished child replaced its exit with
  `killed`; the monitor could spin forever when an exit code could not be
  read; a deadline could fire on a tree that had already finished; `pty info`
  leaked its result on a job query failure; the stdin write handle and a
  callback line object could leak; a directory watch could free its overlapped
  buffer with a read still outstanding.
- **Filesystem.** `dirs`/`links` reported a root that exists but may not be
  opened as `notfound`; out-of-memory was `badvalue`; `canon` asked for data
  access it does not need, turning an unreadable file into `notfound`.
- **Entry, store, winjob.** A first command that cannot be parsed is
  `ENTRY optin`; a read failure while validating an entry carries a code;
  `store get` leaked its result on a finalize failure; job-object failures no
  longer dereference a NULL error pointer; the launcher's UTF-8 conversion is
  strict like every other; the words handed to `Tcl_EvalObjv` are owned.
- **Program support.** `cli` refuses a positional named `help` and never takes
  `--` as an option value; `log configure` refuses `-channel` with `-file`.
- **Build.** `-Werror` is unconditional in the release build (it was behind an
  environment variable nothing set); the reference checker uses the packaged
  prelude list; an orphaned serializer smoke script is gone.

## Candidate studies

- The timeout selectivity study (cross-industry lineage,
  `study-cross-industry.md` in the z estate).

## Roads examined and not taken (2026-08, the runtime tour)

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

## Deferred: the palette gains xml (decided 2026-08-20, deferred 2026-08-22)

Solid XML handling, validation included, was decided on 2026-08-20 as a
palette organ beside `json` — runtime capability, not an extensions-covenant
errand — and deferred on 2026-08-22 so the historical 0.12.0 release could stay
focused. The capability remains decided, but no release is assigned. The
deciding programs are the rail-family operations formats
(railML, NeTEx, TAF/TSI, Darwin push data): schema-described XML is the
data plane of long-lived operations environments, and a runtime that
promises "just works for years" must read it in the box.

Recorded as constraints, not answers — the route is design work:

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

## Candidate additions

Windows registry, services, event log, network facts, users, host facts, and
selected WMI queries remain candidates. None was included in 0.20, and none has
an assigned release. Each needs a concrete program, a narrow Tcl-shaped contract,
structured failures, manifest metadata, and tests on real Windows behavior
before admission.

The extensions covenant (see [External libraries](extensions.md)) names its
own candidate machinery: a wrap-time dependency resolver that classifies a
program's requires as in-box, payload, or tool-local; a hashed manifest beside
the output; and a `--deps` mode that verifies it on the target. The policy
is contracted now; the machinery follows the same admission bar as every
verb.

The route to 1.0 is a smaller surface whose invariants have survived use, not a
longer list of verbs. New policy layers and bundled applications are out of
scope for the runtime itself.
