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
- **Introspection.** A self-describing **manifest** — `help <verb>` → a dict of signature / options / errors — is the intended end-state ([the creed](creed.md) principle 4); it is *not built yet*. Until then the dict-and-errorcode contract below holds, and Tcl's own `info` / ensembles give runtime introspection.

```tcl
set r [run -timeout 30s -- some.exe]      ;# → {exit 0  status ok  out "…"  err ""  pid 8123  truncated {}}
try { run -- missing.exe } trap {MACHTELD RUN notfound} {m opts} {
    dict get $opts -errorcode             ;# {MACHTELD RUN notfound}
}
```

This invariant is why [the creed](creed.md)'s "palette describes itself" and "errors are the contract" are cheap to honour.

## The error-code registry

**This table is the closed set.** A test (`test/run_test.tcl`) scans the C sources and fails if
they can throw a code this table does not name, and fails if the table names a code the C cannot
throw — so trapping by code is safe to rely on, which is the whole point of structured errors.

| Code | Meaning |
|---|---|
| `MACHTELD RUN notfound` | the program could not be resolved on PATH — `run`, `child start`, `pty spawn`, `detach` |
| `MACHTELD RUN nohandle` | the token does not name a live child or pty |
| `MACHTELD RUN launch` | the program was found, but starting it failed (pipe, job, ConPTY, `CreateProcess`) |
| `MACHTELD RUN usage` | malformed invocation — unknown option, missing option value, too many children to wait on |
| `MACHTELD RUN badvalue` | an option's value is ill-formed — a duration without a unit, a bad byte size, a bad exit code |
| `MACHTELD RUN oserror` | a Win32 call failed after launch — reading, writing, killing, waiting |
| `MACHTELD STORE notopen` | a store operation was attempted before `store open` |
| `MACHTELD STORE sqlite` | SQLite reported an error; the *message* is SQLite's wording, the *code* is ours |

**Errors that carry Tcl's own codes, deliberately.** Wrong argument counts throw
`TCL WRONGARGS` (via `Tcl_WrongNumArgs`) and an unknown subcommand throws `TCL LOOKUP INDEX`
(via `Tcl_GetIndexFromObj`). These are structured, trappable and standard, and using Tcl's
vocabulary for Tcl's own failure modes is [creed](creed.md) 7 — extend the language, do not
restate it. They are named here so the registry is complete about what a caller can see, not
only about what machteld itself raises.

**Known wart, recorded rather than hidden:** the domain is `RUN` for every verb in the process
core — `child`, `wait`, `detach` and `pty` all raise `MACHTELD RUN …` because they share one
error helper. The codes are correct; the domain is coarser than the contract's `DOMAIN CODE`
shape implies. Settling it means giving each verb its own domain, which is a change to ~30 call
sites and belongs with the manifest work, not ahead of it.
