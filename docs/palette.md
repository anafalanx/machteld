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

## Built — live file events

```tcl
set w [watch start $dir -recursive]      ;# opaque token "watch#N"
watch read $w                            ;# what changed since the last read; empty if nothing
watch read $w -timeout 5s                ;# block up to 5s for the first event
watch read $w -raw                       ;# the OS stream, unmerged
wait -any $child $w                      ;# "the build finished, OR a file changed"
watch close $w ;  watch list
```

An event is `{path <relative> action <added|modified|removed|renamed> ?from <old>?}`. Paths are
relative to the watched directory and always use forward slashes.

**Coalesced by default: one event per path per read.** A batch is everything since your last
read, so the merge depends on the event sequence and your read points — never on a hidden
timer, which is what keeps the same reads giving the same answer ([creed](creed.md) 3). Saving a
new file emits *added* then *modified*; the surviving action is decided by precedence —
**removed** beats **added** beats **renamed** beats **modified** — so a creation reads as
`added` rather than losing its more informative half. A rename pair is joined into one event
naming both ends. `-raw` gives the unmerged stream when you want exactly what the OS said.

If events are lost — the queue cap, or the OS's own buffer overflowing — the read leads with
`{path {} action overflow count N}` rather than silently returning less.

A blocking `watch read` does not pump Tcl's event loop (nor does `child wait`), so a Tk tool
polls with a short `-timeout` from an `after` handler instead of blocking its UI thread.

**Writing a tool with its own namespace?** The prelude puts the palette on the *global*
namespace path, and Tcl does not consult the global path for a lookup that begins inside
another namespace — so bare `watch` and `run` will not resolve in `namespace eval ::mytool`.
Ask for them once and the rest reads like a script:

```tcl
namespace eval ::mytool { namespace path ::machteld }
```

## Built — the machine's processes

```tcl
ps list                            ;# every process on the box: a list of dicts
ps info 4796                       ;# one of them
ps kill 4796                       ;# terminate it
ps kill 4796 -tree                 ;# and everything it started
```

A row is `{pid ppid name exe mem private cpu threads started access}`. `mem` is the working set
and `private` the private commit, both in bytes; `started` is Unix epoch seconds, so
`clock format` reads it directly; `threads` is the thread count.

**This is the half `child` is not.** `child list` enumerates the processes *machteld started* and
holds them in a job object, so `child kill` is exact. `ps` reaches everything else — and pays for
it in precision: `ps kill -tree` walks a single snapshot, so a tree that is still forking can
outrun it. Use `child`/`scope` for anything you launched yourself.

**`cpu` is cumulative milliseconds, not a percentage.** A percentage is a rate, and a rate needs
two samples and a clock — computing it inside the verb would mean hidden state and an answer that
depended on when you last asked ([creed](creed.md) 3). Take two readings and divide; divide again
by `$env(NUMBER_OF_PROCESSORS)` if you want 100% to mean the whole machine.

**A process you cannot open is not an error.** Without elevation, roughly half the processes on a
normal desktop refuse inspection. They still appear — with `pid`, `ppid`, `name` and `threads`
from the snapshot, `access 0`, and every other field the **empty string** rather than `0`, so
"we were denied" never reads as "it is using no memory". Failing the whole listing over a process
you may not inspect would make the verb useless on exactly the machines it is for.

`ps kill` raises `denied` for a process you lack the rights to end, and `notfound` both for a pid
that never existed and for one that has already exited — Windows reports `ERROR_ACCESS_DENIED`
for a corpse, and reporting that as `denied` would advise elevation over a process that simply
finished.

## Built — text and identity

```tcl
version                            ;# "0.3.0"
vtstrip $text                      ;# remove ANSI/VT escape sequences, keep the text
```

`vtstrip` is pure Tcl and needs no terminal, so it is safe to use on captured `pty read` output
in a headless test. Note `version` is the *palette's* version; `store version` is a different
command reporting SQLite's.

## Built — storage & packaging

```tcl
store open db.sqlite ; store put k v ; store get k ; store keys ; store del k ; store version ; store close
wrap ./mytool -o mytool.exe --gui     ;# stamp a Tcl/Tk tool into a standalone exe (see packaging.md)
```

## Built — JSON

```tcl
json decode {{"name":"x","tags":["a","b"],"n":42}}
    → {name x tags {a b} n 42}                ;# a dict, whose values are dicts/lists/scalars
json encode [dict create a 1 b [list x y]]
    → {"a":1,"b":["x","y"]}
json encode -dict $d ;  json encode -list $l  ;# force the reading of an untyped value
```

Hand-rolled in C straight into `Tcl_Obj` — no intermediate document, and no vendored parser. The
**conformance suite** is vendored instead ([`test/jsontestsuite`](../test/jsontestsuite),
nst/JSONTestSuite, 318 cases): all 95 `y_` cases parse, all 188 `n_` cases are rejected. Of the
35 implementation-defined `i_` cases we accept 31 and reject 4 — the UTF-16 and BOM inputs, since
this decodes UTF-8 and a byte-order mark is not JSON.

**Decode** maps `null` → `""`, `true` → `1`, `false` → `0`, and keeps a number's **literal text**,
so nothing is lost to a double and Tcl 9's bignums keep a 30-digit integer exact.

**Encode reads structure from what the value IS, never from what its text looks like.** A dict
object becomes an object, a list object an array, anything else a scalar — so a decoded document
round-trips byte-for-byte, and `dict create` / `list` do the right thing for one built by hand.
Guessing from the text would make every string containing a space an array; `-dict` and `-list`
force the reading when a value has no type of its own. Two consequences worth stating: a value
is emitted as a JSON *number* only if it is already a valid JSON number literal — so `01234`
stays the string `"01234"` rather than silently becoming `1234` — and booleans and nulls do not
round-trip, because Tcl has neither. See [the contract](contract.md).

## Built — digests, HMAC and cryptographic random

```tcl
hash sum sha256 $data              ;# hex digest of a value
hash sum sha256 $data -binary      ;# the raw 32 bytes instead
hash file sha256 big.iso           ;# streamed; 64 KB of memory whatever the size
hash hmac sha256 $key $data
hash random 32                     ;# 32 unguessable bytes

set h [hash start sha256]          ;# hash#1 -- stateful, so it is a token
hash update $h $chunk
hash final $h                      ;# the digest, and the token is gone
hash list ; hash algorithms
```

`md5 sha1 sha256 sha384 sha512`, over Windows CNG — already on the machine, so nothing is
vendored and there is no OpenSSL. Verified against the published NIST and RFC 2202/4231 vectors
and against `Get-FileHash`; 25 MB streams in about 30 ms.

**Which bytes get hashed is the part worth reading.** A Tcl value is not bytes — it is a value
with a byte representation that depends on how you ask, and hashing the Latin-1 view of `café`
gives a different answer from hashing its UTF-8. The rule is the one [`json encode`](#) already
follows: read what the value **is**, never what its text looks like.

- a **byte array** — from `binary decode`, or a channel read in binary mode — hashes those bytes
  exactly;
- **anything else** hashes its UTF-8, so `hash sum sha256 abc` agrees with `sha256sum`,
  `certutil` and `Get-FileHash`.

`hash file` opens through the Tcl channel layer with `-translation binary`, so zipfs paths work
and a digest never depends on line endings.

**`hash random` is the only unguessable source in the palette.** `expr {rand()}` is a
deterministic PRNG seeded from the clock; it is fine for jitter and must never be used for a
token, a nonce or a temporary name that someone might predict.

## Built — observing a handle without disturbing it

```tcl
watch info $w                      ;# {token dir recursive armed pending dropped}
pty info $p                        ;# {token pid running pending}
```

`child` has always had `info`; these give the other two handle verbs the same. The point is what
they do **not** do: `watch read` drains the event queue and `pty read` consumes the child's
output, so anything built on those to answer "what is pending?" would be stealing from the
program that owns the handle. These report queue depth and pending bytes and take nothing away,
and the suite checks that repeated calls leave both untouched.

`watch info` also reports `dropped`, which is the only way to learn that events were lost
without draining the queue to find out.

## Built — self-description

```tcl
manifest                                          ;# one dict describing the whole palette
dict get [manifest] run options                   ;# {-cpu -dir -env -mem -onerr -onout -stdin -timeout}
dict get [manifest] pty subcommands read options  ;# -timeout
help ; help palette                               ;# the docs bundle, from inside the exe
```

Derived, never hand-written — the C half from the source at build time, the Tcl half from the
live interpreter. See [the contract](contract.md).

## Deferred — designed, not built

The machine-control **domains** `reg` / `svc` / `evt`, and later `net` / `wmi` / `host` / `user`
— our own C, with TWAPI as a quarry for WMI/COM only (see
[ecosystem policy](ecosystem-policy.md)). Also deferred: the `say` / `csv` / `fs` / `clock`
conveniences — Tcl's own `file` / `env` / `clock` cover much of that today.

None of these is scheduled. `watch` and `ps` both arrived because a tool asked — the
change-viewer needed live file events, the task manager needed a view of processes machteld did
not start — and that remains the best reason to build one, because it is also when the dict shape
stops being a guess. It is no longer the *only* reason: [rule 5](direction.md) was rewritten on
2026-08-09 to allow building a domain to find out what it wants to be. What holds instead is that
nothing is frozen before 1.0.0 anyway, so a shape built to find out is free to change once you
have found out.
