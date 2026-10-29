---
id: machteld/command/pmap
type: command
title: pmap
summary: Execute one worker-request batch in parallel with automatic pool cleanup.
commands: pmap
---

# pmap

## Synopsis

```tcl
pmap requests ?-width n? ?-maxtries n? ?-maxframe bytes? ?-maxitems n? \
    ?-maxbatch bytes? ?-maxresults bytes? ?-timeout duration? ?-raw? \
    ?--? command ?arg ...?
```

## Arguments and options

`requests` is the same list of operation dicts accepted by `pool submit`.
`-width` defaults to 4, `-maxtries` to 1, and `-timeout` to 5 minutes. `-raw`
returns complete replies instead of plain result values. `command` starts the
worker executable; pool launch resource options are not supported here.
`-maxframe`, `-maxitems`, `-maxbatch`, and `-maxresults` have the same meanings,
integer validation and defaults as `pool create`: 16 MiB per UTF-8 frame,
10000 requests, 64 MiB of submitted frames and 64 MiB of retained replies.
Limits and width/attempt options are validated even for an empty request list.

## Results

Default mode returns handler `result` values in submission order. With `-raw`,
returns complete ordered reply dicts including failures. An empty request list
returns empty without launching workers.

## Errors

Own failures are `PMAP badvalue`, `PMAP failed`, `PMAP launch`, `PMAP limit`, `PMAP timeout`,
and `PMAP usage`. Without `-raw`, the first failed reply in submission order is
raised: a structured handler code propagates unchanged; missing/`NONE` handler
code becomes `PMAP failed`. Pool setup/wait errors are restated in PMAP domain.

## Lifetime and timeouts

`pmap` creates one pool, submits, waits, and closes it on every completion path,
including errors. `-timeout` bounds the batch wait after creation/submission,
not total call time; cleanup then terminates any remaining worker trees. The
wait runs a nested Tcl event loop, so timers and GUI callbacks may run before
`pmap` returns. Do not call it halfway through a widget/model update.

One attempt is the default: losing a reply does not prove that the operation
had no effect. `-maxtries n` explicitly allows up to n total attempts, and is
appropriate only for replay-safe operations. A reported handler failure is
never retried. Exhausted lost replies retain code `MACHTELD POOL poison`,
including when raised by non-raw pmap; the outcome may be uncertain, and
neither timeout nor cleanup rolls back side effects.

## Examples

```tcl
set requests [lmap path $paths {dict create op digest path $path}]
set digests [pmap $requests -width 8 -timeout 2m -- worker.exe]
set replies [pmap $requests -raw -- worker.exe]
```

## Constraints

This maps named worker operations over data, not Tcl scripts or closures. It is
appropriate when work amortizes process and JSON framing overhead. For partial
success inspection use `-raw`; default semantics fail like `lmap`.

## See also

`machteld/command/pool`, `machteld/command/worker`,
`machteld/guide/parallel`.
