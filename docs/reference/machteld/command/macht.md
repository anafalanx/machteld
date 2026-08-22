---
id: machteld/command/macht
type: command
title: macht
summary: Command engines - disposable Lua compute processes under the engine contract - through one lifecycle-and-work family.
commands: macht
---

# macht

## Synopsis

```tcl
macht start ?-threads N? ?-memory SIZE? ?-exe PATH?
macht stop ?TOKEN?
macht status ?TOKEN?
macht load -lines PATH ?-engine TOKEN?
macht load -csv PATH ?-schema SPEC? ?-header? ?-engine TOKEN?
macht def NAME CHUNK ?-engine TOKEN?
macht run NAME ?ARG ...? ?-json TEXT? ?-shards N? ?-reduce NAME2? \
    ?-budget DURATION? ?-engine TOKEN?
macht free HANDLE ?-engine TOKEN?
macht stats ?TOKEN?
macht conform EXE ?ARG ...?
```

## Arguments and options

One verb owns an engine's whole life, in the palette's usual handle shape.
An engine is the Machteld executable in engine mode - or, with `-exe`, any
executable speaking the wire of `machteld/guide/engine` - run as a
supervised child in the host's Job Objects.

`start` returns an engine token. `-threads` bounds the engine's shard
threads (default: logical cores, capped); `-memory` is a hard process
limit enforced by the engine's job; `-exe` starts a sidecar instead of the
built-in engine. Work subcommands accept `-engine TOKEN`; without it, the
first work subcommand lazily starts one default engine with default
limits, and later work reuses it.

`load` sends a path - never bytes - and returns a pool handle. `-lines`
builds one string column, `line`; `-csv` (a declared capability an engine
may lack) parses RFC 4180 records under a `-schema` of name/type pairs
(`i`, `f`, `s`) with an optional `-header`.

`def` sends a Lua chunk that must leave a global function `NAME`; chunks
are cached by content hash, so redefining identical text is free. `run`
calls it. Arguments are scalars or handles; a structured argument is JSON
text built with `json encode` and passed once as `-json`. `-shards N` runs
the kernel over N contiguous views of the first pool argument and returns
the list of partials in shard order; `-reduce NAME2` folds that list
engine-side and returns the single value. `-budget` is a wall-clock limit
enforced by killing the engine.

`conform` starts `EXE` (with optional arguments), runs the bounded
protocol fixture suite against it, and reports.

## Results

`start` returns a token; `stop` and `free` return nothing. `status` and
`stats` return dicts of engine facts and counters. `load` returns a pool
handle. `def` returns the kernel name. `run` returns the kernel's value
under the boundary's edge laws: exact 64-bit integers; Lua booleans as
`1`/`0`; a top-level `nil` as the empty string; non-finite floats as the
tagged dict `{float nan|inf|-inf}`; containers by the `json` command's
mapping. A result larger than the wire ceiling returns a `res#` handle
instead, with the spill counted in `stats`. `conform` returns
`{ok 0|1 checks {{name 0|1} ...}}`.

## Errors

Domain `MACHT`, closed set: `usage`, `badvalue`, `noengine` (no engine
could be started, or the token names none), `died` (the engine exited or
closed its pipe; its handles are gone), `nohandle`, `type` (a value could
not cross the boundary), `lua` (kernel compile or runtime failure, with
the Lua message and traceback), `budget`, `memory`, `refused` (a
capability this engine did not declare in `hello`), `protocol`, and
`conform`.

## Lifetime and timeouts

The host owns every engine absolutely: engines are children in the root
and per-engine Job Objects, die with `stop`, with their `scope`, with the
program, or with a `-budget` breach - always by the job, never by
negotiation. The engine is a cache, never the truth: after `died` or
`budget`, every handle and kernel of that engine is gone, and the next
work subcommand lazily starts a fresh default engine. Nothing a program
depends on may live only in an engine. `-budget` uses the shared duration
grammar and is the only limit that holds against a kernel stuck inside a
single C call.

## Examples

```tcl
set h [macht load -lines C:/data/access.log]
macht def hits {function hits(h)
    local n = 0
    for i = 1, h.rows do
        if string.find(h.line[i], "404", 1, true) then n = n + 1 end
    end
    return n
end}
set total [macht run hits $h]
set parts [macht run hits $h -shards 8]
macht def sum_of {function sum_of(ps)
    local s = 0
    for i = 1, #ps do s = s + ps[i] end
    return s
end}
set total [macht run hits $h -shards 8 -reduce sum_of]
macht free $h
macht stop
```

## Constraints

Kernels are trusted as written: there is no translation, no oracle, and
no runtime verification - the build gates prove the machine (the engine,
the wire, the boundary, the loader), and testing a kernel is the program
author's optional work. The kernel environment is Lua 5.5 with `base`,
`string`, `table`, `math`, `utf8`, the vendored `lpeg` and `cjson`, and
- as a negotiated capability on AVX2 hosts - the `col` primitive library
(see the engine contract's "The col library"); no `io`, `os`, `package`,
or `debug`.
Handles are engine-scoped and never guessed; a handle offered to another
engine is `nohandle`. `-shards` above the engine's thread bound is
refused. A kernel returning a string shaped exactly like a handle is
indistinguishable from a spill at the caller; name results accordingly.
Topology is flat: engines never start engines, and Tcl is the only
spawner.

## See also

`machteld/guide/engine` - the full contract: the wire, the boundary's
three roads, sharding, limits, sidecar engines. `machteld/guide/parallel`
- pools carry commands; engines hold data. `machteld/command/child` for
the supervision machinery underneath.
