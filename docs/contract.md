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
- **The Tcl half** is read out of the live interpreter by `manifest` itself — the prelude's own
  verbs, and `namespace ensemble configure -map` for a C verb the prelude extends, which is how
  `pty expect` appears beside the five subcommands written in C.

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
| `PTY` | `pty` (all subcommands) |
| `WATCH` | `watch` (all subcommands) |
| `STORE` | `store` (all subcommands) |

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
| `oserror` | a Win32 call failed after launch — reading, writing, killing, waiting |
| `notopen` | a `store` operation was attempted before `store open` |
| `sqlite` | SQLite reported an error; the *message* is SQLite's wording, the *code* is ours |

Not every domain raises every code: `store` raises only `notopen` and `sqlite`; `nohandle`
comes from `child`, `wait`, `pty` and `watch`. The pairs that matter are pinned by behavioural
tests. `watch start` on a directory it cannot open raises `notfound`, the same code a missing
program gets — in both cases the thing you named is not there.

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
