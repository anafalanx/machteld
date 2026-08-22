---
type: contract
title: The engine
description: The 0.12.0 engine contract - an out-of-process trusted Lua engine commanded by a Tcl program over a language-neutral wire.
tags: [machteld, engine, macht, lua, contract, wire]
---

# The engine

This page is the contract for the Machteld 0.12.0 engine. Implementation
lands against it across the 0.12.0 phases (see the [roadmap](roadmap.md)) -
engine mode, the wire, the boundary, the `macht` family, the `lines`
loader, and the kernel libraries (utf8, LPeg, lua-cjson) are present; the
`csv` loader arrives behind the same `hello` capability negotiation, so a
program asks the engine what it carries rather than assuming. The page,
the `macht` manifest entry, and the behavior must agree.

## What the engine is

The engine is the Machteld executable itself, started in engine mode: a
disposable compute process holding Lua 5.5, LPeg, lua-cjson, the Lua `utf8`
library, and typed data pools. There is no Tcl and no Tk in that process. A
Machteld program commands engines through one verb family, `macht`: it starts
them, points them at files, sends kernels as Lua source, receives answers, and
kills them. Every host that can start an engine can be one: the direct
executable, the console basekit, and the GUI basekit all carry engine mode, so
a wrapped tool brings its engine with it and nothing is ever installed.

Five rules govern everything on this page.

1. **The control plane is Tcl and only Tcl.** A program's control flow, events,
   user interface, supervision, and contracts live in Tcl. Foreign code is
   machinery: named units the program starts, feeds, questions, and kills. A
   kernel never calls back into the program, never owns an event, never draws.
2. **Computation runs where the data lives.** Data loaded into an engine is
   computed on by that engine. Tcl-born values cross to an engine only as
   bounded arguments; engine-born data crosses back to Tcl only as bounded
   answers. A payload never passes through the control plane.
3. **The engine is a cache, never the truth.** An engine may be killed at any
   instant - by budget, by scope, by the program, by the operating system. The
   program may start another and load again. Nothing a program depends on may
   live only in an engine.
4. **The machine is proven; kernels are trusted.** Machteld's build gates prove
   the engine, the wire, the boundary, and the loaders. A kernel is never
   checked, sampled, or verified at run time; it is trusted exactly as any
   program is trusted. Testing a kernel is the program author's work, and
   optional.
5. **Additive.** A program that never calls `macht` starts nothing and loses
   nothing: the complete Tcl/Tk runtime and palette remain the base case.
   `worker`, `pool`, and `pmap` remain the fan-out for Tcl-shaped work.

## The macht family

One verb owns an engine's whole life, in the palette's usual shape (`pty`,
`watch`, `store`): lifecycle, work, and introspection are subcommands.

```tcl
package require machteld 0.12.0

set e [macht start -threads 8 -memory 2G]     ;# explicit engine (optional)
set h [macht load -csv C:/data/access.csv -schema {name s path s status i bytes i}]
macht def hot {
    function hot(h)
        local n = 0
        for i = 1, h.rows do
            if h.status[i] == 404 then n = n + h.bytes[i] end
        end
        return n
    end
}
set waste [macht run hot $h]                   ;# one value back
set parts [macht run hot $h -shards 12]        ;# twelve partials back
set total [macht run hot $h -shards 12 -reduce sum_of]
macht free $h
macht stop $e
```

| Subcommand | Contract |
|---|---|
| `macht start ?-threads N? ?-memory SIZE? ?-exe PATH?` | Start an engine; returns an engine token. `-threads` bounds the engine's shard threads (default: logical cores). `-memory` is a hard process limit enforced by the engine's Job Object. `-exe` starts a sidecar engine instead of the built-in one. |
| `macht stop ?TOKEN?` | Ask the engine to quit, then kill the tree. Every handle of that engine becomes invalid. |
| `macht status ?TOKEN?` | Observe without consuming: pid, uptime, capabilities, handle count, memory accounting. |
| `macht load -csv PATH ?-schema SPEC? ?-header?` / `macht load -lines PATH` | Road 3: the engine reads the file itself and builds a pool; returns a pool handle. |
| `macht def NAME CHUNK` | Send a Lua chunk; it runs once in the kernel environment and must leave a global function `NAME`. Cached by source hash. |
| `macht run NAME ?ARG ...? ?-json TEXT? ?-shards N? ?-reduce NAME2? ?-budget DURATION?` | Call the kernel with arguments and return its value; see the boundary and sharding sections. |
| `macht free HANDLE` | Release a pool or result handle. |
| `macht stats ?TOKEN?` | Counters for the engine: frames, bytes, runs, spills, last run time, cached kernels. |
| `macht conform EXE` | Run the conformance suite against an executable and report. |

Every work subcommand accepts `-engine TOKEN`. Without it, the first work
subcommand lazily starts one default engine for the program, with default
limits; `macht start` exists for control and for additional engines. The exact
option sets are claimed by the 0.12.0 manifest; this page fixes the vocabulary
and its semantics.

`macht` is not a grammar, not a compiler, and not a translation of anything. The
chunk given to `def` is Lua, written by the program author, run as written.

## The wire

The wire is language-neutral by construction so that any executable can be an
engine. It is deliberately boring.

- **Transport.** The engine's standard input and output, in binary mode. Standard
  error is diagnostics and never protocol; the host drains and caps it.
- **Frames.** Each message is one frame: a 4-byte little-endian unsigned length
  followed by exactly that many payload bytes. A payload is one UTF-8 JSON
  object. Frames larger than 64 MiB are a protocol failure.
- **Requests and replies.** The host sends requests carrying a positive integer
  `id` and an `op`; the engine answers each request with exactly one reply
  carrying the same `id`, in request order, and sends nothing unsolicited.
  A reply is `{"id":N,"ok":true,...}` or `{"id":N,"ok":false,"error":{"code":C,"message":M}}`.
- **Handshake.** The first request is `hello`. The engine's reply names itself
  and declares its capabilities; the host never uses a capability that was not
  declared, and refuses with `MACHT refused` when a program asks for one.

```json
-> {"id":1,"op":"hello","protocol":1,"host":"machteld","version":"0.12.0"}
<- {"id":1,"ok":true,"engine":"machteld","version":"0.12.0","protocol":1,
    "capabilities":["lua","load.csv","load.lines","shards","reduce","stats"]}
-> {"id":2,"op":"load","format":"csv","path":"C:/data/access.csv",
    "schema":["name","s","path","s","status","i","bytes","i"],"header":true}
<- {"id":2,"ok":true,"handle":"pool#1","rows":1000000,
    "fields":["name","path","status","bytes"]}
-> {"id":3,"op":"def","name":"hot","chunk":"function hot(h) ... end"}
<- {"id":3,"ok":true,"name":"hot","hash":"3b1c..."}
-> {"id":4,"op":"run","name":"hot","args":[{"handle":"pool#1"}],"shards":12,"reduce":"sum_of"}
<- {"id":4,"ok":true,"value":38413829,"ms":14.6}
-> {"id":5,"op":"free","handle":"pool#1"}
<- {"id":5,"ok":true}
-> {"id":6,"op":"quit"}
<- {"id":6,"ok":true}
```

The operations are `hello`, `load`, `def`, `run`, `free`, `stats`, `cancel`,
and `quit`. `cancel` is advisory: a cooperative engine may abandon the current
run and reply to it with code `cancelled`; the host never relies on it. The
guarantee is the kill.

Protocol version 1 is this page. A future version is negotiated in `hello`;
an engine that does not understand the host's version says so in its reply,
and the host reports `MACHT protocol`.

## Lifecycle

The host owns an engine absolutely. An engine is born as a supervised child in
the host's root Job Object and a per-engine job; it dies with `macht stop`,
with the `scope` it was started in, with the program, or with a budget or
memory breach - always by the job, never by negotiation. `TerminateJobObject`
is always available and always correct: rule 3 makes every engine disposable.

Death is observed, not inferred. When the engine's pipe closes or its process
exits, every handle and cached kernel of that engine is invalid; the next use
of any of them raises `{MACHTELD MACHT died}` with the exit status in the
message. A program recovers by starting another engine and loading again.

Residency is within the program's lifetime: an engine outlives any number of
runs, holds pools and compiled kernels between them, and answers the second
question without reloading. An engine that outlives its program - a resident
daemon shared across runs - is contracted direction, not 0.12.0 behavior (see
the last section).

Topology is flat: **threads inside, engines across.** Data parallelism is the
shard threads inside one engine over one pool. Task parallelism is a program
starting several engines, each an ordinary supervised child with its own token
and job. The built-in engine never starts processes, and the contract has no
notion of an engine's children: a sidecar's interior - threads or private
helpers - is its own affair inside its job cage, and the job catches the
subtree. Tcl is the only spawner.

## The boundary

Values cross the wire on three roads. The rules are the `json` palette
command's rules wherever they apply, so one map serves both organs.

**Road 1 - values, by copy, under a ceiling.** Arguments to `run` and the value
it returns:

| Tcl | wire | Lua |
|---|---|---|
| integer (64-bit) | JSON integer (no point, no exponent) | integer |
| double | JSON number with point or exponent | float |
| string | JSON string, UTF-8 | string (bytes) |
| list / dict (via `-json`) | JSON array / object | sequence table / table |
| `1` / `0` from a Lua boolean | `true` / `false` | boolean |
| empty string from a Lua nil | `null` | nil |

Edge laws, each one stated once:

- A JSON array arrives in Lua as a **1-based** sequence; a Lua sequence
  (keys 1..n, no holes) leaves as an array; any other Lua table leaves as an
  object and must have string keys. A hole - a `nil` inside a container -
  cannot cross and raises `MACHT type`.
- Lua `true`/`false` arrive in Tcl as `1`/`0`. Tcl has no booleans: a Tcl `0`
  crossing into Lua is the **number 0, which is truthy in Lua**. Kernel authors
  compare explicitly.
- Integers are exact 64-bit in both directions; a float whose textual form has
  no point or exponent is not an integer and is not guessed into one.
  Non-finite floats cross as the tagged object `{"float":"nan"|"inf"|"-inf"}`.
- Strings are UTF-8. A Lua string that is not valid UTF-8 cannot cross and
  raises `MACHT type`; binary data stays in the engine (road 2) or in files
  (road 3).
- `run` arguments are scalars or handles. A structured argument is JSON text
  built with `json encode -dict`/`-list` and passed once as `-json TEXT`;
  results return through `json decode`'s rules, with number text kept exact.
- The ceiling is 1 MiB of wire payload per value. A larger result is not
  truncated and not refused: the engine keeps it and returns a **result
  handle** instead, the reply carries `"spilled":true`, and `macht stats`
  counts it. A large result is a design smell under rule 2, and the smell is
  measured, not hidden.

**Road 2 - handles, for everything engine-resident.** Pools and spilled
results are opaque tokens owned by one engine. A kernel receives a pool as an
object `h` with `h.rows` and one indexable column per field, `h.<field>[i]`,
`i` from 1 to `h.rows`; in the 0.12.0 built-in engine the columns of a shard's
view are materialized Lua sequences, so the measured kernel numbers apply
directly. A handle offered to a different engine, or after its engine died or
`free`d it, raises `MACHT nohandle`. Handles are never guessed, never
re-used, never serialized.

**Road 3 - paths, for bulk.** `load` sends a path; the engine reads the file.
The host normalizes the path and the engine's working directory is the
program's at start. A schema is pairs of field name and type, `i` (64-bit
integer), `f` (double), or `s` (string); a field that fails to parse under its
type is a `load` error naming the line. `-csv` reads RFC 4180 records:
quoted fields, doubled quotes, embedded newlines, CRLF and LF, an optional
header. `-lines` builds one string column, `line`. The 0.12.0 loader is a
correct single-thread parser; its throughput is measured, not promised.

**Kernels.** A chunk crosses as source text, compiles in the engine, and is
cached by source hash: defining the same text twice costs nothing. The kernel
environment is Lua 5.5 with `base`, `string`, `table`, `math`, `utf8`, `lpeg`,
and `cjson`; there is no `io`, no `os`, no `package`, no `debug`. A kernel's
error - compile or runtime - raises `{MACHTELD MACHT lua}` with the Lua
message and traceback as the message text, and the engine survives it.

## Sharding

`macht run NAME H ... -shards N` runs the kernel `N` times in parallel threads
inside the engine, each call receiving a **view** of the first pool argument
covering a contiguous row range, with `view.rows` and the same columns, and
the remaining arguments unchanged. Without `-reduce`, the reply is the list of
the `N` return values in shard order and the program reduces it - twelve
partials are a bounded answer. With `-reduce NAME2`, the engine calls
`NAME2(partials)` once, in one state, with the Lua sequence of partial values,
and returns its value. `N` above the engine's `-threads` is refused
(`MACHT badvalue`). The engine's thread count is the commander's budget:
several engines on one machine oversubscribe only when the program says so.

## Limits and kill

`-budget DURATION` on `run` is a wall-clock limit on that run. On breach the
host kills the engine - not the run, the engine - and raises
`{MACHTELD MACHT budget}`; every handle of that engine is gone. This is the
only limit that is always enforceable: a kernel inside one long C call (a
pathological parse, a huge decode) never returns to the Lua VM and can be
stopped by nothing cooperative. `-memory SIZE` on `start` is enforced the
same way by the Job Object; breach raises `{MACHTELD MACHT memory}` on the
next use. Phase 0 measured a kill of an engine spinning inside one C call at
32-38 ms from request to reaped, with a fresh engine answering `hello`
immediately after.

## Errors

Domain `MACHT`, closed set: `usage`, `badvalue`, `noengine` (no engine could
be started, or `-exe` did not start), `died`, `nohandle`, `type`, `lua`,
`budget`, `memory`, `refused` (capability not declared by this engine),
`protocol` (malformed frame, unknown version, or reply out of contract), and
`conform`. A kernel's own `error()` is `lua`; a protocol failure from a sidecar
is `protocol`. The message is for a person and may contain engine text.

## Sidecar engines

Any executable that speaks this wire is an engine. `macht start -exe PATH`
starts it exactly as the built-in one, in the same jobs, with the same
lifecycle, observed the same way. It declares its capabilities in `hello`; a
sidecar need not offer `lua`, and may offer vendor capabilities named with a
prefix (`acme.vectors`). Under the deployment covenant a sidecar ships **in the
folder** beside the program, with its license text, or it is not in the
program. `macht conform EXE` runs the fixture suite - handshake, capability
sanity, the boundary's edge laws, a load/def/run round trip where `lua` is
declared, budget kill, death and restart - and returns a report dict
`{ok 0|1 checks {...}}`. The built-in engine is the reference implementation
and passes its own suite in Machteld's build gates.

## What Phase 0 measured

The proto-engine spike (`_reken`, 2026-08-22, 1M rows × 7 fields, 12 shards)
grounds this contract: control frames round-trip in 41-64 µs; a kernel runs
across the process boundary at parity with the in-process record (12.6-18.2
ms against 14.3 ms same-day, inside the machine's own noise); a warm engine
answers a full command-to-value round trip in 13-19 ms against the ~2 758 ms
Tcl-side cold path it replaces; the engine loads a million rows to resident in
178 ms; and an engine spinning inside one C call is killed and reaped in 32-38
ms with a clean respawn. The whole engine, Lua included, is 300 KB.

## What this page does not promise in 0.12.0

- A program-independent resident engine - a daemon shared across runs - is
  contracted direction: it will speak this same wire over a named pipe and
  outlive its starter by `detach`, with a rendezvous and an idle policy, and
  it is not in 0.12.0.
- Bulk transfer of large Tcl-born data into an engine. Road 1's ceiling
  applies to arguments; data larger than that goes to a file and enters by
  road 3.
- Parallel ingestion. The 0.12.0 loader is one thread; the sharded,
  schema-specialized loader is its own measured project.
- Engines on other machines. The wire is local stdio; nothing on this page
  addresses a network.
