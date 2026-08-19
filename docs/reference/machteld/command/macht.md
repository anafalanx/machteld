---
id: machteld/command/macht
type: command
title: macht
summary: Compiled, metered calculation over loaded rows, written in plain Tcl expr syntax.
commands: macht
---

# macht

## Synopsis

```tcl
macht load rows -schema {field type ...}
macht sum {expr} where {cond} -data handle ?-intent intent? ?-budget n? ?-parallel n|auto?
macht count where {cond} -data handle ?-intent intent? ?-budget n? ?-parallel n|auto?
macht info handle
macht close handle
macht stats
macht reset
```

## Arguments and options

`load` takes a list of rows (each a list matching the schema) and a
`-schema {field type ...}` declaration where every type is `i` (64-bit
integer) or `s` (string, stored as UTF-8 bytes). It returns a `data#N`
handle.

The condition and the sum expression are **Tcl expr syntax**: `$field`
references from the schema, integer literals, `"string"` literals
(without backslashes or substitution), `+ - * %`, comparisons,
`&& || !`, parentheses, `abs(...)`, and `[string match "pattern" $field]`
with `*` wildcards only. Nothing else — see Errors for what is refused
and why.

`-intent` is one of `auto` (default), `once`, `{sweep K}`, or
`sandboxed`. `-budget n` sets the instruction budget for `sandboxed`
runs. `-parallel n|auto` shards the handle across an in-process pool of
metered Lua states and reduces integer partials; it does not combine
with `sandboxed`.

## Results

`sum` and `count` return exact 64-bit integers. `info` returns a dict
(`n`, `schema`, `marshalled`, `pmarshalled`, `spent_ms`). `stats`
returns the routing log: one `{fingerprint route ms note}` entry per
decision, including `calibrate` entries whose note records that the
oracle held.

## Errors

All errors are `{MACHTELD MACHT code}`.

- `refused` — the surface names constructs whose Tcl and Lua meanings
  diverge, and refuses them rather than approximating: `?` or `[]` in a
  match pattern (characters vs. bytes), `[string length ...]`
  (characters vs. bytes), string ordering with `< <= > >=` (collation),
  backslashes or substitution inside string literals, any command
  outside the whitelist.
- `parse`, `type` — malformed surface text; schema/type violations.
- `badvalue` — bad handles, options, schema shapes, intent forms.
- `state` — an oracle disagreement (the route is refused, never
  trusted) or a Lua state failure.
- `call` — a kernel failed in the cell: an exhausted instruction
  budget or the memory cap, with the reason in the message.
- `thread` — worker thread creation failed.

## Lifetime and timeouts

`load` retains the rows until `close`. The first route that needs the
metered cell (or the pool) creates it; `reset` closes everything and
clears the calibration cache and the routing log. Kernels are pure by
construction — no io, no os, no ambient state — so a `sandboxed` run is
bounded by its `-budget` and by the cell's memory cap, and a runaway is
an error, not a hang.

## Examples

```tcl
package require machteld 0.11.0
set h [macht load $rows -schema {naam s pad s status i bytes i}]
set waste [macht sum {$bytes} where {$status == 404 && [string match "/api/*" $pad]} -data $h]
set big [macht count where {$bytes > 90000} -data $h -intent {sweep 50}]
set risky [macht sum {$bytes} where {$status >= 500} -data $h -intent sandboxed -budget 50000000]
set fast [macht sum {($a * $b + $c) % 97} where {$status < 500} -data $h -parallel auto]
macht close $h
```

## Constraints

The condition text runs verbatim as the Tcl arm, so Tcl semantics are
authoritative by construction; the generated Lua arm must prove itself
equal on a sample before any route trusts it, and the same run measures
whether Lua earns its marshal. Routing is economics, logged in `stats`;
`sandboxed` is law and never downgrades. There is no way to submit Lua
text: the seam is closed by decision, and `LuaCell` is a private
primitive.

## See also

`machteld/command/pmap` (process-level parallelism for tools),
`machteld/command/store`, `machteld/command/manifest`.
