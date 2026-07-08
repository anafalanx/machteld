---
type: convention
title: The contract — everything is a dict
description: Data, failure, and self-knowledge share one shape — a Tcl dict.
tags: [machteld, contract, dict, errors, introspection]
timestamp: 2026-07-07
---

# The contract — everything is a dict

The whole surface obeys one invariant: **data, failure, and self-knowledge are the same shape — a Tcl dict** (JSON-isomorphic). One mental model covers output, errors, and the capability manifest.

- **Return values.** Data verbs return dicts; stateful verbs return an **opaque handle token** (see [execution model](/execution-model.md)).
- **Errors.** Native Tcl `try` / `throw`; every palette error carries a structured `-errorcode {DOMAIN CODE detail}` plus a machine-readable detail dict. Errors are part of the contract, not prose to string-match.
- **Introspection.** A runtime self-description facility (`help <verb>` → a dict of signature/options/errors) that can emit a full machine-readable **manifest**. The palette is its own source of truth.

```tcl
set r [run cargo build -timeout 30s]      ;# → {status ok exit 0 dur 4.21 out "…" err ""}
try { run missing.exe } trap {PROC ENOENT} {m opts} {
    dict get $opts -errorcode              ;# {PROC ENOENT {path missing.exe}}
}
help run   ;# → {verb run summary "supervised execution" options {…} errors {…} returns dict}
```

This invariant is why [the creed](/creed.md)'s "palette describes itself" and "errors are the contract" are cheap to honour.
