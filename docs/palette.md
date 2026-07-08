---
type: reference
title: The palette
description: Surface conventions, hybrid shape, and the v1 verb set (execution core + essentials + svc/reg).
tags: [machteld, palette, verbs, reference, v1]
timestamp: 2026-07-07
---

# The palette

## Surface conventions

- **Options:** Tcl-classic `-flag value`, with a `--` guard separating our options from the external command's args.
- **Values:** human units (`30s`, `5m`, `1G`, `256M`, `80%`) accepted and normalized to canonical typed values (the type is reported in the manifest — see [the contract](/contract.md)).
- **Output:** captured into the result dict by default (capped); opt-in streaming via a sink (`-onout {line}` / `-out $chan`).

## Shape & organization

**Hybrid:** a small set of flat top-level verbs for the hot execution path; **ensembles** (`noun verb`) for stateful handles and machine-control domains. Every ensemble is self-describing — its subcommand list is a manifest for that domain.

## v1 — execution core (flat, the wedge)

```tcl
run -timeout 30s -mem 1G -cpu 60s -cwd $dir -- cargo build
    → {exit 0  status ok  dur 4.21  out "…"  err ""}
    # run IS `child start` in blocking mode: one option surface, no duplication.

set c [child start -mem 256M -- server.exe]        ;# → opaque handle
child limit $c -cpu 60s
child info  $c        → {pid 8123 state running mem 210M cpu 3.4}
child kill  $c                                     ;# whole-tree kill, guaranteed
child list           → {…live handles…}

wait $a $b -any -timeout 5m                         ;# multiplex over handles
scope { set s [child start db.exe]; run migrate.exe }    ;# s dies at the brace
detach [child start watchdog.exe]                        ;# opt out: survive the tool

set p [pty spawn -- ssh admin@box]                  ;# interactive — linear expect
pty send   $p "$pw\n"
pty expect $p {                                     ;# classic pattern/action block,
    "password:" {send $pw}                          ;#   also returns {matched … before …}
    "denied"    {die "auth failed"}
    timeout     {die "no prompt"}
}
```

(Runtime semantics — linear + bounded lifetime — are in the [execution model](/execution-model.md).)

## v1 — essentials (cross-cutting)

`say` / `warn` / `die` · `store` (SQLite: `store put/get/keys/del`, `store sql …`) · `json` / `csv` · `fs` (read/write/glob/stat) · `env` · `clock`

## v1 — domains (ensembles)

Our own C; TWAPI is a quarry for WMI/COM only (see [ecosystem policy](/ecosystem-policy.md)).

```tcl
svc restart nginx        ;   svc status $name   → {state running pid … start auto}
svc list                 → {…services…}
reg get  HKLM/Software/…/Version   → typed value
reg set  HKCU/…/Flag 1 -type dword
reg keys HKLM/Software/Vendor
```

**Deferred to v1.x:** `evt` (event log), `net`, `host` (os/hardware), `wmi`, `user`.
