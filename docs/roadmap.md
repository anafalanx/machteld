---
type: roadmap
title: Roadmap
description: What Machteld 0.11.0 contains and how possible additions are ordered.
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

## 0.12.0 — the cell grows capabilities

Three additions are committed, not candidates. Each enters as an emitter
capability under the oracle — never as user-facing Lua; the seam stays
closed — and the two vendored libraries enter through the dependency lock
exactly as Lua itself did.

1. **Open the built-in `utf8` library in the cell** and implement
   character semantics in the emitter: `utf8.len` agrees with Tcl's
   `string length` on characters, converting today's `string length`
   refusal into a proven construct. Zero vendoring; the admission test is
   an é-heavy oracle fixture agreeing across all arms.
2. **LPeg** (MIT, pinned lock entry): parsing inside kernels at C speed —
   the ingestion direction's substrate, starting with in-cell field
   splitting. Admitted with byte-honest semantics specified against their
   Tcl counterparts, oracle-proven or refused by name.
3. **lua-cjson** (MIT, pinned lock entry): JSON decoded inside the cell so
   kernels run over JSON-lines data directly. The palette's `json` verb
   remains the Tcl-side organ; this is in-kernel data access, not a
   shadow of it.

## Candidate additions

Windows registry, services, event log, network facts, users, host facts, and
selected WMI queries remain candidates. None is promised by 0.11.0. Each needs a
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
