---
type: roadmap
title: Roadmap
description: What Machteld 0.14.0 contains and how possible additions are ordered.
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

## Stabilization before breadth

1. Gate the opt-in parser, direct host, both wrapped hosts, and `EntryCheck`
   against the same entry corpus.
2. Check every manifest command, subcommand, option, result key, and error code
   against behavior, including protocol reply codes.
3. Stress process-tree cleanup, channel closure, ConPTY teardown, worker death,
   pool replacement, SQLite contention, and atomic wrapper failure paths.
4. Keep package versions and the machine-control/data surface identical across
   all produced executables; test the documented distribution-only exceptions.
5. Measure startup, idle memory, and packaging size after the product cut.

## 0.12.0 — the engine

The release moves all Lua out of the host process and replaces the 0.11.0
`macht` grammar with an engine: the executable in engine mode, commanded by
the `macht` verb family over a language-neutral wire, under the contract in
[the engine](engine.md). Committed, in build order; each phase ends with every
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
contract section "The col library" in [the engine](engine.md). Filters
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
of [the engine](engine.md):

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

## 0.15.0 candidates

- The timeout selectivity study (cross-industry lineage,
  `study-cross-industry.md` in the z estate).
- A smarter `topn` selection pass: the banked worst-case evidence
  (~1 s for a descending click on a monotone column) is its driving
  workload; admitted only by a registered prediction against that
  number.
- The sharded, schema-specialized loader: byte-range parallel parsing
  into column pools, admitted only by a registered throughput
  prediction.
- A resident engine daemon over a named pipe, with rendezvous and idle
  policy.
- A sidecar conformance kit: the `macht conform` fixtures packaged for
  engine authors in other languages.

## Deferred: the palette gains xml (decided 2026-08-20, deferred 2026-08-22)

Solid XML handling, validation included, was decided on 2026-08-20 as a
palette organ beside `json` — runtime capability, not an extensions-covenant
errand — and deferred on 2026-08-22 to an unspecified later version, so that
0.12.0 stays about one thing. The decision stands; only its release is
unassigned. The deciding programs are the rail-family operations formats
(railML, NeTEx, TAF/TSI, Darwin push data): schema-described XML is the
data plane of long-lived operations environments, and a runtime that
promises "just works for years" must read it in the box.

Recorded as constraints, not answers — the route is design work:

- The leading vendor candidate is tDOM 0.9.7 (C, Tcl 9-ready, bundles
  expat 2.7.3): DOM, XPath, DTD validation, and its own schema engine,
  statically linkable the way SQLite and Lua entered, pinned through the
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
selected WMI queries remain candidates. None is promised by 0.14.0. Each needs a
concrete program, a narrow Tcl-shaped contract, structured failures, manifest
metadata, and tests on real Windows behavior before admission.

The extensions covenant (see [External libraries](extensions.md)) names its
own candidate machinery: a wrap-time dependency resolver that classifies a
program's requires as in-box, payload, or sidecar; a hashed manifest beside
the output; and a `--deps` mode that verifies it on the target. The policy
is contracted now; the machinery follows the same admission bar as every
verb.

The route to 1.0 is a smaller surface whose invariants have survived use, not a
longer list of verbs. New policy layers and bundled applications are out of
scope for the runtime itself.
