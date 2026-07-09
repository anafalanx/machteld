---
type: reference
title: The palette
description: Surface conventions and the verb set — what is built (execution core, pty, store, wrap) and what is deferred.
tags: [machteld, palette, verbs, reference]
timestamp: 2026-07-09
---

# The palette

## Surface conventions

- **Namespace + bare verbs:** every command is `::machteld::<verb>`; the prelude also exposes them unqualified (via `namespace path`) so scripts read like a shell — without shadowing any core Tcl command.
- **Options:** Tcl-classic `-flag value`, with a `--` guard separating machteld's options from the external command's args.
- **Values:** durations carry an explicit unit (`500ms`, `30s`, `5m`, `2h`) — a bare number is **rejected**, so `-timeout 100` can never silently mean 100 seconds. Byte sizes take `K`/`M`/`G`.
- **Results:** a dict. `run` returns `{exit status out err pid truncated}` (`status` ∈ `ok` / `error` / `timeout` / `killed`).
- **Errors:** thrown with a structured `-errorcode {MACHTELD RUN <code>}`.

## Built — execution core

```tcl
run -timeout 30s -mem 1G -cpu 60s -dir $d -stdin $text -env {K V} -- some.exe
    → {exit 0  status ok  out "…"  err ""  pid 8123  truncated {}}
run -onout {handle_line} -- long.exe    ;# live per-line streaming to a callback (-onerr for stderr)

set c [child start -mem 256M -- server.exe]  ;# opaque token "child#N"
child info $c   → {running 1 …}
child kill  $c                                ;# whole-tree kill, guaranteed
child wait  $c  → {exit … status … out … err …}
child list ;  child close $c

wait -any $a $b                               ;# multiplex over children
scope { child start db.exe ; run migrate.exe }    ;# children born inside die at the brace
detach -- watchdog.exe   → 8140               ;# fire-and-forget daemon; returns a pid
```

(Runtime semantics — linear + bounded lifetime — are in the [execution model](execution-model.md).)

## Built — interactive (ConPTY)

```tcl
set p [pty spawn -- cmd]
pty send $p "echo hi\r"
pty expect $p -timeout 5s {
    {*hi*}   { … }
    timeout  { … }
}
pty read  $p -timeout 100ms     ;# raw read; vtstrip $text strips ANSI/VT escapes
pty close $p
```

## Built — storage & packaging

```tcl
store open db.sqlite ; store put k v ; store get k ; store keys ; store del k ; store version ; store close
wrap ./mytool -o mytool.exe --gui     ;# stamp a Tcl/Tk tool into a standalone exe (see /packaging.md)
```

## Deferred — designed, not built

The machine-control **domains** `svc` (services) and `reg` (registry), and later `evt` / `net` / `wmi` / `host` / `user` — our own C, with TWAPI as a quarry for WMI/COM only (see [ecosystem policy](ecosystem-policy.md)). Also deferred: the `say`/`json`/`csv`/`fs`/`clock` conveniences (Tcl's own `file` / `env` / `clock` cover much of this today), and the self-describing runtime **manifest** ([creed](creed.md) principle 4).
