---
type: contract
title: The engine
description: The engine contract - an out-of-process trusted Lua engine commanded by a Tcl program over a language-neutral wire.
tags: [machteld, engine, macht, lua, contract, wire]
---

# The engine

This page is the contract for the Machteld engine, implemented in full by
the current executable: engine mode, the wire, the boundary, the `macht`
family, the `lines` and `csv` loaders, the kernel libraries (utf8, LPeg,
lua-cjson), and - since 0.13.0 - the `col` primitive library. The 0.12.0
release built the engine; 0.13.0 added the primitives. Capabilities are
negotiated in `hello` - a program asks an engine what it carries rather
than assuming, which is also how a sidecar with a narrower surface stays
honest. The page, the `macht` manifest entry, and the behavior must agree.

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
package require machteld 0.13.0

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
| `macht stats ?TOKEN?` | Counters and occupancy gauges for the engine: frames, bytes, runs, spills; kernels held against `kernel_slots` with `kernel_evictions`; spilled `results` against `result_slots`; cached `views` with `view_evictions`; per-state `mem_used` against `cap_bytes`; `dict_limit_override` (0 unless the uncontracted bench instrument is set); per-pool `dict_cols`, `span_cols`, and the governing `dict_limit` - the Plimsoll lines a long-lived program watches. |
| `macht conform EXE` | Run the conformance suite against an executable and report. |

Every work subcommand accepts `-engine TOKEN`. Without it, the first work
subcommand lazily starts one default engine for the program, with default
limits; `macht start` exists for control and for additional engines. The exact
option sets are claimed by the manifest; this page fixes the vocabulary
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
-> {"id":1,"op":"hello","protocol":1,"host":"machteld","version":"0.13.0"}
<- {"id":1,"ok":true,"engine":"machteld","version":"0.13.0","protocol":1,
    "capabilities":["lua","load.csv","load.lines","shards","reduce","stats","col"]}
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
daemon shared across runs - is contracted direction, not present behavior (see
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
`i` from 1 to `h.rows`. In the built-in engine a column materializes as a
plain Lua sequence on its FIRST touch and stays in the table from then on
(one metamethod hit per column; loops run at the measured kernel numbers) -
so a kernel that computes only through `col` never materializes anything,
which is what lets `col` work over pools far larger than the state cap. A
column too large for the cap refuses at the touch with the allocator's
"not enough memory" as `MACHT lua`; the engine survives. The view cache
keeps at most two ranges per state per pool, evicting the oldest; a kernel
still holding an evicted view keeps a valid table while the pool lives. A
stashed view whose pool was `free`d keeps answering for columns it already
materialized and refuses `col: view outlives its pool` on the first
untouched one - never a stale read. `pairs(h)` sees only `rows` and the
touched columns; the contract is `h.rows` and `h.<field>`, never
enumeration (and a column literally named `rows` shadows the row count -
name columns accordingly). A handle offered to a different engine, or
after its engine died or `free`d it, raises `MACHT nohandle`. Handles are
never guessed, never re-used, never serialized.

**Road 3 - paths, for bulk.** `load` sends a path; the engine reads the file.
The host normalizes the path and the engine's working directory is the
program's at start. A schema is pairs of field name and type, `i` (64-bit
integer), `f` (double), or `s` (string); a field that fails to parse under its
type is a `load` error naming the line. `-csv` reads RFC 4180 records:
quoted fields, doubled quotes, embedded newlines, CRLF and LF, an optional
header. `-lines` builds one string column, `line`. The loader is a
correct single-thread parser; its throughput is measured, not promised.

**Kernels.** A chunk crosses as source text, compiles in the engine, and is
cached by source hash: defining the same text twice costs nothing. The
kernel table holds 256 names; a 257th distinct name evicts the least
recently run kernel, whose next `run` refuses as `no kernel` until it is
defined again - an engine never refuses a definition. The kernel
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

## The col library

Kernels on a capable host carry `col`: precompiled column primitives that
reach the pool's native memory directly, at memory-bandwidth speed. The
capability is negotiated - the engine declares `col` in `hello` only when
its CPU carries AVX2; on any other host the library simply is not opened,
and kernels fall back to ordinary Lua loops. The primitives are plain
autovectorized C by measured verdict (hand intrinsics earned residence
nowhere); they stand on the invariant that **pools are read-only after
load**, which is what makes concurrent shard reads lawful.

The vocabulary, over a view `h`:

- `col.filter(h, FIELD, OP, X)` with OP in `"lt" "le" "gt" "ge" "eq"
  "ne"`, over an `i` or `f` column, returns a **selection**. Float
  comparisons are IEEE: NaN matches nothing except `ne`; a NaN probe
  matches nothing except `ne`, which then matches every row. Over an
  `s` column, OP is `"eq"`, `"ne"`, or `"match"` and X is a string;
  comparisons are **byte-exact** (UTF-8 bytes, no collation, no case
  folding). `match` is the glob dialect with `*` only - `?` and `[`
  are refused by name (`col: match knows only *`) - and a `*` crosses
  any byte, an embedded newline included. `match` on a numeric column
  and the ordering ops on a string column refuse by name.
- `col.sum(h, FIELD ?, SEL?)` - integer sums are exact int64, computed in
  4096-element chunks proven wraparound-free (a chunk that cannot be
  proven falls back to per-element checked adds), and an overflow raises
  `col: integer overflow` deterministically. Float sums follow the
  normative row-striped eight-lane tree: lane `k mod 8` accumulates row
  `k`, a masked-out row contributes `+0.0`, lanes fold left to right - so
  every float sum is deterministic to the bit, and a selected NaN
  propagates.
- `col.sumwhere(h, FIELD, BYFIELD, OP, X)` - the fused one-pass form over
  any pairing of `i`/`f` value and predicate columns; prefer it to
  filter-plus-sum when the predicate is used once. BYFIELD may also be
  an `s` column with the string ops - "sum bytes where the path matches
  the api prefix" is one pass.
- `col.distinct(h, FIELD)` and `col.values(h, FIELD)` over a
  dictionary-mode `s` column: the number of distinct values, and the
  distinct strings as a sequence in first-appearance order (a filter
  dropdown in one call). The dictionary is pool-wide - a view over a
  subrange still answers for the whole column. On a span-mode column
  both refuse by name (`col: field ... is past the dictionary limit`);
  a zero-row column answers empty (0, `{}`), never that refusal.
- `col.min(h, FIELD ?, SEL?)`, `col.max(...)` - NaN is skipped; the
  result seeds at the first surviving element; nothing surviving raises
  `col: empty selection`. `col.count(h)` and `col.count(SEL)`.
- `col.band(A, B)`, `col.bor(A, B)`, `col.bnot(A)` - selection algebra
  for compound predicates worth reusing; bits beyond the view's rows
  stay zero, always.
- `col.rows(h, SEL_or_nil, FIRST, COUNT)` - the bounded page: rows of
  the view in row order, or the FIRST-th..(FIRST+COUNT-1)-th
  **selected** rows under SEL, as a sequence of row sequences in pool
  column order. FIRST is 1-based like everything on the boundary;
  FIRST past the population yields an empty sequence (a scrolled-past
  page is an empty page, not an error); COUNT above 4096 refuses by
  name. It reads pool memory directly - dictionary or span alike, no
  column materialization - so a GUI pages a pool of any size: filter,
  count, fetch fifty rows, one kernel, one round trip.
- `col.groupcount(h, BYFIELD ?, SEL?)` and `col.groupsum(h, FIELD,
  BYFIELD ?, SEL?)` - the chart verbs: `{keys, counts}` /
  `{keys, counts, sums}` as parallel sequences in first-appearance
  order, every group included, empty ones too. BYFIELD is a
  dictionary-mode `s` column (the group set is the pool-wide
  dictionary; sharded partials align by index) or an `i` column
  (bounded at 65,536 groups, refused by name past that; the group set
  is the VIEW's rows with SEL ignored - the selection masks only the
  counting - and sharded partials align by KEY, never by index, since
  each shard numbers its own first appearances). Grouping by a float
  field refuses. Integer sums are exact per-element checked adds;
  float sums accumulate sequentially per group. A zero-row column
  answers empty. One caveat carried by the boundary, not the verb: a
  column holding non-UTF-8 bytes groups fine in-cell, but returning
  its keys raw fails the reply at the UTF-8-strict wire - map or drop
  such keys in the kernel before returning.
- `col.topn(h, FIELD, N, SEL_or_nil, DIR)` - the order-by verb: the N
  rows with the largest (`"desc"`) or smallest (`"asc"`) FIELD under
  SEL, as rows in pool column order like `col.rows`, strongest first.
  Ties break by row order (earlier rows win a place; equal values
  ascend by row in the output), deterministically. NaN rows never
  enter; N above 4096 refuses by name; FIELD is `i` or `f`.

**Dictionary encoding.** At load, every `s` column is dictionary-encoded:
the distinct values are numbered in first-appearance order and the column
stores one small code per row (4 bytes where the span form costs 16). The
string primitives then run their predicate once per **distinct** value and
sweep integer codes - which is why `match` over a million rows costs about
a millisecond, not a Lua loop's ninety. The cardinality escape is
explicit and **rows-relative**: past
`min(1,048,576, max(65,536, rows / 8))` distinct values the dictionary is
discarded and the column stays in span mode - every operation stays
byte-for-byte correct, only slower, and `distinct`/`values` refuse. The
rule is the measured economics: every dictionary it admits has at least
eight rows per distinct value, which guarantees the memory win and a
measured >= 4x speed margin even at the boundary. One consequence, stated
plainly: the mode is a property of the LOADED POOL, never of the file's
schema - between loads of different sizes the same column can flip in
either direction (a bigger load usually gains dictionaries; a column
whose full-file cardinality is past the 1,048,576 cap can dictionary on a
sample and escape at scale). Every span-mode refusal stays named. The
mode is visible: `stats` reports `dict_cols`, `span_cols`, and the
governing `dict_limit` on every pool. Kernels see nothing of any of
this - a materialized view holds the same Lua strings in either mode.

Selections are engine furniture: per-state userdata through the metered
allocator, bound to full view identity (the monotone pool number plus the
row range), freed by garbage collection. A selection offered to another
view is refused by name; a selection or view whose pool was freed refuses
with `col: view outlives its pool` rather than touching a stale pointer;
a selection can never cross the boundary (the wire refuses userdata as
`MACHT type`). The library's refusals - `col: unknown field`, `col: field
... is not numeric`, `col: argument type`, `col: selection is bound to
another view`, `col: view outlives its pool`, `col: integer overflow`,
`col: empty selection`, `col: match knows only *`, `col: match needs a
string field`, `col: op ... needs a numeric field`, `col: field ... is
not a string`, `col: field ... is past the dictionary limit` - are Lua
errors and surface as `{MACHTELD MACHT lua}` with the message intact.

Three pieces of measured guidance, not law: a single `col` call outruns
the twelve-shard Lua path several times over, so arithmetic no longer
needs `-shards` - shard for kernels that do real per-row Lua work, not
for primitives; a span-mode predicate walks every row (~82 ns/row
measured), so at tens of millions of rows a keystroke-driven filter
costs seconds - debounce that lane, while dictionary columns stay
keystroke-fast at any measured scale; and for anything the vocabulary
cannot express, the fallback is the ordinary Lua loop over the
materialized columns, in the same kernel, beside the same data.

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

## What this page does not promise in 0.13.0

- A program-independent resident engine - a daemon shared across runs - is
  contracted direction: it will speak this same wire over a named pipe and
  outlive its starter by `detach`, with a rendezvous and an idle policy, and
  it is not in 0.13.0.
- Bulk transfer of large Tcl-born data into an engine. Road 1's ceiling
  applies to arguments; data larger than that goes to a file and enters by
  road 3.
- Parallel ingestion. The loader is one thread; the sharded,
  schema-specialized loader is its own measured project.
- Engines on other machines. The wire is local stdio; nothing on this page
  addresses a network.
