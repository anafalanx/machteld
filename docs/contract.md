---
type: convention
title: The contract — everything is a dict
description: Data, failure, and self-knowledge share one shape — a Tcl dict.
tags: [machteld, contract, dict, errors, introspection]
timestamp: 2026-07-07
---

# The contract — everything is a dict

The whole surface obeys one invariant: **data, failure, and self-knowledge are the same shape — a Tcl dict** (JSON-isomorphic). One mental model covers output, errors, and the capability manifest.

- **Return values.** Data verbs return dicts; stateful verbs return an **opaque handle token** (see [execution model](execution-model.md)).
- **Errors.** Native Tcl `try` / `throw`; every palette error carries a structured `-errorcode {DOMAIN CODE detail}` plus a machine-readable detail dict. Errors are part of the contract, not prose to string-match.
- **Introspection.** The **manifest** ([the creed](creed.md) principle 4). `manifest` takes no arguments and returns one dict describing the whole palette — navigate it with `dict get`, so no subcommand vocabulary is invented and none has to be frozen.

```tcl
set r [run -timeout 30s -- some.exe]      ;# → {exit 0  status ok  out "…"  err ""  pid 8123  truncated {}}
try { run -- missing.exe } trap {MACHTELD RUN notfound} {m opts} {
    dict get $opts -errorcode             ;# {MACHTELD RUN notfound}
}
```

## The manifest — the palette describing itself

```tcl
dict keys [manifest]                              ;# every palette verb
dict get [manifest] run options                   ;# {-cpu -dir -env -mem -onerr -onout -stdin -timeout}
dict get [manifest] run returns                   ;# {err exit out pid status truncated}
dict get [manifest] pty subcommands read options  ;# -timeout
dict get [manifest] child codes                   ;# what `child` can throw
```

Fields: `kind` (`c` or `tcl`), `domain`, `codes`, `options`, `returns`, `subcommands` (a dict
of subcommand → `{options …}`), and `args` for Tcl-written verbs.

**Nothing here is hand-maintained**, which is what separates self-description from a second
copy of the truth. The two halves are derived by two means, for one reason — C cannot be asked
about itself at runtime and Tcl can:

- **The C half** is extracted from `src/*.c` at build time by `tools/genmanifest.tcl`: the
  `Tcl_GetIndexFromObj` subcommand tables, the option literals the parser compares against, the
  result-dict keys, and every domain and code reaching `Tcl_SetErrorCode`.
- **The Tcl half** is read out of the live interpreter by `manifest` itself, from `info args`
  and **`info body`** — the verb's actual body in the actual interpreter, so it cannot drift and
  it works inside a tool sourced from the exe's own zipfs. A prelude verb's `domain` and `codes` come from its `Fail`
  calls, its `options` from the two idioms the prelude uses to test them (a `switch` arm and an
  equality against a literal), and a shared helper told its caller's domain (`_dur2ms PTY $v`)
  has what it raises attributed to the verb that called it — the same problem `parse_opts` poses
  on the C side, solved the same way.
  `namespace ensemble configure -map` covers a C verb the prelude extends, which is how
  `pty expect` appears beside the five subcommands written in C **with its own `-timeout` and its
  own `timeout` code**: a subcommand written in Tcl is exactly as visible as one written in C.

  Until 2026-08-09 this half stopped at `kind tcl` plus `args`, so the prelude's verbs had no
  domain, no codes and no options at all. That was survivable for two verbs and would not have
  been for [the standard library](stdlib.md), which lands in the prelude — creed 4 would have
  decayed in exact proportion to how much library got added.

The suite holds the result to the *running binary*: subcommands are compared against what
`Tcl_GetIndexFromObj` actually enumerates in its error message, `returns` against the dict `run`
actually answers with, and declared options against what the parser actually accepts. Adding a
subcommand to the C table without exposing it fails the suite.

This invariant is why [the creed](creed.md)'s "palette describes itself" and "errors are the contract" are cheap to honour.

## The error-code registry

Every failure is `{MACHTELD <DOMAIN> <code>}`. **The domain is the verb you called** — so you
trap on the command you typed, never on which internal helper happened to fail.

| Domain | Raised by |
|---|---|
| `RUN` | `run` |
| `CHILD` | `child` (all subcommands) |
| `WAIT` | `wait` |
| `DETACH` | `detach` |
| `DIRS` | `dirs` and `links` — one walker, two questions, so one domain |
| `PTY` | `pty` (all subcommands) |
| `WATCH` | `watch` (all subcommands) |
| `STORE` | `store` (all subcommands) |
| `JSON` | `json` (all subcommands) |
| `MTPS` | `mtps` (all subcommands) |
| `WRAP` | `wrap` — stamp a Tcl/Tk directory into a standalone exe |
| `HELP` | `help` |
| `HASH` | `hash` (all subcommands) |
| `CLI` | `cli` |
| `LOG` | `log` (all subcommands) |
| `FRONT` | `front` — the workspace front door |
| `MIRROR` | `mirror` — the recovery replica. Its own domain and not `FRONT`'s, because its refusals are the substance of the command rather than a failure of the front door to resolve something |
| `TCL` | `tcl` — run a script as this process's program |
| `JOURNAL` | `journal` — the front door's record |
| `WORKER` | `worker` (all subcommands) |
| `POOL` | `pool` (all subcommands) |
| `PMAP` | `pmap` — its own failures only; a worker's failure keeps its own domain |

**The code set below is closed.** A test (`test/run_test.tcl`) scans the C sources and fails if
they can throw a code this table does not name, *and* fails if the table names a code the C
cannot throw — so trapping by code is safe to rely on, which is the whole point of structured
errors.

| Code | Meaning |
|---|---|
| `notfound` | the program could not be resolved on PATH — `run`, `child start`, `pty spawn`, `detach` |
| `nohandle` | the token does not name a live child or pty |
| `launch` | the program was found, but starting it failed (pipe, job, ConPTY, `CreateProcess`) |
| `usage` | malformed invocation — unknown option, missing option value, too many children to wait on |
| `badvalue` | an option's value is ill-formed — a duration without a unit, a bad byte size, a bad exit code |
| `oserror` | a Win32 call failed after launch — reading, writing, killing, waiting; or `dirs` could not allocate the walk |
| `notopen` | a `store` operation was attempted before `store open` |
| `sqlite` | SQLite reported an error; the *message* is SQLite's wording, the *code* is ours |
| `parse` | the text is not valid JSON; the message says what was wrong and where it stopped |
| `depth` | nesting past the 512 limit, on the way in or out — refused rather than crashing the stack |
| `denied` | the OS refused the operation on a process you do not have the rights to touch |
| `timeout` | a bounded wait ran out — `pty expect` with no pattern matched in time |
| `unsupported` | this build cannot do it — `wrap` or `help` on a host with no embedded payload, or a manifest key the front door has yet to implement |
| `failed` | a pooled item failed with no code a caller could trap on — its handler raised a plain `error` |
| `noroot` | no workspace was found at or above the executable — there is no `.mt` (nor `.z`) |
| `manifest` | the workspace manifest is missing, unreadable, or does not describe what was asked for |

Not every domain raises every code: `store` raises only `notopen` and `sqlite`; `nohandle`
comes from `child`, `wait`, `pty` and `watch`. The pairs that matter are pinned by behavioural
tests. `watch start` on a directory it cannot open raises `notfound`, the same code a missing
program gets — in both cases the thing you named is not there.

The registry scan reads the prelude as well as `src/*.c`, because creed 5 says errors are part
of the contract without saying "the errors written in C". **Every** prelude error now carries a
code: the prelude used to raise eleven bare `return -code error` with none, which put its verbs
outside the registry entirely, and the suite now *fails* if an uncoded one reappears rather than
merely counting them.

Several domains are raised from Tcl rather than C — `FRONT`, `HELP`, `LOG`, `POOL` among them — and the prelude has its own
raiser, `Fail domain code msg`, mirroring the C's `mt_error`. A shared helper is told which
domain to raise in (`_dur2ms PTY $v`), for the same reason the C option parser is: **the domain
is the verb you called**, never the helper that happened to fail.

`denied` is the one code that reports a *permission*, and it is confined to `mtps`, because `mtps`
is the one verb that reaches processes machteld did not start. Note what it does **not** cover:
a process `mtps list` cannot open is not an error at all — it comes back as a row with
`access 0` and its unreadable fields empty. Failing the whole listing over a process you may
not inspect would make the verb useless on exactly the machines it is for.

```tcl
try { pty spawn -- missing.exe } trap {MACHTELD PTY notfound} {m opts} { … }
try { wait child#99 }            trap {MACHTELD WAIT nohandle} {m opts} { … }
```

**Errors that carry Tcl's own codes, deliberately.** Wrong argument counts throw
`TCL WRONGARGS` (via `Tcl_WrongNumArgs`) and an unknown subcommand throws `TCL LOOKUP INDEX`
(via `Tcl_GetIndexFromObj`). These are structured, trappable and standard, and using Tcl's
vocabulary for Tcl's own failure modes is [creed](creed.md) 7 — extend the language, do not
restate it. They are named here so the registry is complete about what a caller can see, not
only about what machteld itself raises.

**`MACHTELD TCL` and Tcl's own `TCL` are not the same thing, and cannot be confused by a trap.**
The `tcl` verb raises in domain `TCL` because the rule is *the domain is the verb you called*, and
the verb is called `tcl`. Tcl's own codes begin with `TCL` in the **first** position
(`{TCL WRONGARGS}`); every machteld code begins with `MACHTELD` (`{MACHTELD TCL usage}`). A `trap`
matches on a prefix of the list, so the two never overlap — but they read alike, which is why it is
said here rather than left to be noticed.
