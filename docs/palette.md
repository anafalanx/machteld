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
store open                            ;# no path: an in-memory database, gone when you close it
wrap ./mytool -o mytool.exe --gui     ;# stamp a Tcl/Tk tool into a standalone exe (see packaging.md)
```

**`store open` with no path gives an in-memory database** — useful for a test, and for code that
should work the same whether or not it is later pointed at a file.

**Know the cliff between the two.** Measured at 20,000 keys:

| | in memory | on disk |
|---|---|---|
| `store put` | 246,914/sec | **132/sec** |
| `store get` | 384,615/sec | 25,974/sec |

Writing to a file costs about **7.6 ms per `put`**, because each one is its own transaction and
pays a disk sync. That is fine for settings and state — the things `store` is for — and ruinous
for anything in a loop. If you are writing thousands of rows, you want a different shape, not a
faster `store`: see [parallelism](parallel.md), where an append-only log measured 105,263/sec.

**And if you only want in-memory key-value, Tcl already has it and is faster.** A plain `array`
does the same job at 1.5M sets and 2.9M gets per second — six or seven times quicker than
in-memory `store`, with no verb at all. The reason to use `store` in memory is not speed; it is
that the *same code* works against a file later.

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

## Built — saying what happened

```tcl
log configure -level info -file app.log   ;# or -channel stderr
log info  "watching" dir $d count 3
log warn  "queue filling" pct 91
log error "cannot open" path $p
log configure                             ;# level, channel, file, and drops
```

Levels are `debug info warn error`, ordered, plus `off`. A line reads:

```
2026-08-09T15:53:06.832 INFO  watching dir=C:/dev/_machteld count=3
```

**A write failure never throws.** This is the decision the rest hangs on. A wrapped GUI exe is
started with **no standard channels**, so `puts stderr` raises there — and a log call that can
throw is a log call that kills the program at whatever arbitrary point it was asked to record
something. A failed write increments a counter instead, and `log configure` reports it: the same
bargain [`watch`](#) makes with its `dropped` count. Losing data silently is unacceptable, so it
is counted and reported; it does not become an exception in the middle of unrelated work.

**Pairs after the message are structure, not decoration.** [Creed](creed.md) 2 says
machine-legible and human-legible should be the same thing, and a log line is where that
principle is most often abandoned. Values containing spaces or quotes are quoted, so a line can
be read back. A dangling key with no value renders as `key=?` rather than raising — the caller's
mistake must not cost the message, which is being written precisely because something is already
going wrong.

`-file` **appends**: a tool restarting must not erase the record of why it restarted. Changing
the sink closes the channel `log` opened, so the file is not locked for the life of the process.
`-level` and `-channel` are checked when configured rather than discovered later by silence.

## Built — a pool in one call

```tcl
set reqs [lmap p $paths {list op digest path $p}]
set digests [pmap $reqs -width 8 -- $exe --worker]      ;# results, in submission order
set replies [pmap $reqs -raw -width 8 -- $exe --worker] ;# the raw replies instead
```

Sugar over [`pool`](#), and it earns its place for two reasons rather than brevity.

**The pool is always closed.** Create, submit, wait, close is four calls with three chances to
leak a pool of live worker processes if anything between them raises. Here the close happens on
every path, so a failure costs an error rather than a fistful of orphans.

**A worker's failure is re-raised with the worker's own errorcode.** `pool` hands back replies,
failures included, because a director usually wants to see all of them. A *map* is different —
`lmap` does not return error markers, it propagates. So `pmap` returns plain results, and if an
item failed it raises **that item's** error carrying the code it was raised with *in the worker*:

```tcl
try { pmap $reqs -- $exe --worker } trap {MACHTELD HASH notfound} {m} { … }
```

That is the error contract having travelled the whole way — raised in one process, trappable in
another, unflattened. `pmap`'s **own** failures are `{MACHTELD PMAP …}`, because the domain is the
verb you called; a worker's failure is not pmap's failure, and relabelling it would erase the only
useful thing about it. A handler that raises a plain `error` has errorcode `NONE`, which nothing
can trap on, so that becomes `{MACHTELD PMAP failed}` rather than a code that means nothing.

**It takes an op the worker registered, never a script block.** A closure cannot cross a process
boundary, and shipping script text per item would hand every worker an `eval` and defeat the
bytecode caching that makes a handler worth calling twice. Workers are configured once, then fed
data — the same reason `worker on` defines a proc. Building the requests stays ordinary Tcl, which
is what `lmap` is for.

## Built — a pool of persistent workers

```tcl
set p [pool create -width 8 -- $exe --worker]
pool submit $p {{op digest path a.iso} {op digest path b.iso}}
pool wait   $p -timeout 60s        ;# results, IN SUBMISSION ORDER
pool info   $p                     ;# width, pending, inflight, dead, requeued, stderr
pool close  $p
```

Built on `child start -channels`, never raw `open |cmd r+` — the transport was never the missing
piece, so the whole reason this is a verb is the half Tcl cannot supply. **Every worker is an
ordinary supervised child**: born in a job object, dying with its parent, tree-killed rather than
asked to stop, cappable with `-mem`, and reaped by [`scope`](#) at the closing brace.

**No polling anywhere.** `chan event` on each worker's stdout does the multiplexing that
`wait -any` does by blocking, so a Tk tool stays responsive and an idle pool costs nothing.

**Results come back in submission order.** Replies arrive in whatever order workers finish, which
is not an order any caller asked for; the id is the item's index, so the answer is handed back
aligned with what went in.

**One item in flight per worker** — a legibility choice rather than a throughput one. With a
single outstanding request, the mapping from a reply to the item it answers is a fact rather than
a correlation, and a worker that dies has exactly one item to put back. A dying worker is
detected, its item requeued, and an item that has killed `-maxtries` workers is answered
`{MACHTELD POOL poison}` instead of looping forever.

A failing item keeps **its own** errorcode: `{ok 0 code {MACHTELD HASH badvalue} msg ...}` rather
than something flattened to prose, so the contract survives the process boundary.

> **Stderr is drained, and that is not housekeeping.** A channel-mode child's stderr is a real
> pipe — unlike a plain subprocess, which inherits the console's — and a pipe nobody reads fills
> and blocks the worker *mid-write*: a hang, not an error. The pool reads it on its own
> `chan event` and keeps the tail, capped, for `pool info` to report, because worker diagnostics
> are usually the only evidence of why a pool went wrong.

Measured: 2.62× on 8 workers for 65 ms items, and a pool of **width 1 costs 0.98×** against doing
the same work in-process — the protocol overhead is nearly free, so the useful lower bound on item
size is set by the work, not by the plumbing.

## Built — persistent workers

```tcl
child start -channels -- $exe --worker    ;# the child's pipes become Tcl channels
dict get [child info $tok] stdin          ;# ... reachable through child info
```

```tcl
# in the worker process
worker on digest {path {alg sha256}} { hash file $alg $path }
worker ops                                ;# {digest {path {alg sha256}}}
worker serve                              ;# a line in, a line out, until EOF
```

`-channels` hands a child's pipes to Tcl instead of draining them into buffers, which is what
makes a **persistent** worker possible: the 26 ms of process startup is paid once rather than per
item, and a round trip costs about **159 µs**. It is exclusive with capture — one pipe cannot have
two consumers — so it refuses `-onout`, `-onerr` and `-stdin`, and the result dict keeps its
documented shape with `out` and `err` simply empty.

**Every supervision guarantee still applies**, which is the whole reason this is a verb rather
than `open |cmd r+`: a channel-mode child is born in a job object, dies with its parent, is
tree-killed by `child kill`, capped by `-mem`, killed by `-timeout`, and reaped by `scope`.

**The handler's argument list is the request schema.** `worker on digest {path {alg sha256}}`
says a digest request carries `path` and may carry `alg`; the dispatcher binds them from the
request by name, so `worker ops` can answer what this worker accepts. It also means a handler is
necessarily a **proc**, whose body Tcl compiles — the same loop at top level runs 3.6× slower, so
a design inviting top-level bodies would give most of the parallelism back.

One JSON object per line each way: `json encode` escapes newlines, so a value can never split its
own record and `gets` is a safe frame reader. A failing handler answers
`{ok 0 code {...} msg ...}` with **its own errorcode**, so the contract survives the process
boundary; a malformed line is answered rather than fatal.

> **A handler must not write to stdout.** Stdout *is* the protocol — a stray `puts` injects a line
> that is not a reply. Use [`log`](#), which goes to stderr or a file.

## Built — declaring a tool's arguments

```tcl
set spec {
    --interval {type int    default 2000 min 100 help "refresh interval, ms"}
    --format   {type string default text choices {text json} help "output format"}
    --all      {type flag                help "show everything"}
    dir        {type string default .    help "directory to watch"}
}
set opt [cli parse $argv $spec]      ;# a dict: interval, format, all, dir, help
cli usage $spec tasks                ;# the help text, from the same declaration
```

Every program `wrap` stamps needs argument parsing, and every one used to write its own. A name
beginning `--` is an option, anything else is a positional taken in declaration order, and `--`
ends option parsing. Attributes: `type` (`flag` / `int` / `string`), `default`, `min`, `max`,
`choices`, `required`, `help`.

**It prints nothing and never exits.** An `argparse`-style "print usage and exit" is invisible
exactly where it matters most: a wrapped GUI exe starts with **no standard channels**, so a tool
reporting a bad argument on stdout reports it to nowhere. So `--help` comes back as a value in
the dict, and a bad argument raises `{MACHTELD CLI usage}` whose message already contains the
usage block — the tool decides whether that goes to stderr, a dialog or a log.

**The spec is a dict, not a mini-language.** `{--interval int 2000..}` would mean inventing
syntax to parse, which is what [rule 1](direction.md) exists to prevent. `min` and `choices` are
ordinary keys, so the next attribute is a key too rather than new punctuation.

**Two codes, because two different people make the mistakes.** `usage` is the *user's* — an
unknown option, a missing value, a number out of range. `badvalue` is the *author's* — an unknown
attribute, an unknown type, a name declared twice. A tool can show the first and should fail on
the second.

The bug it removes is real: `tasks --interval` with nothing after it used to set the interval to
the empty string, and `after ""` then threw out of the refresh timer, killing the tool at
startup. A missing value is now refused where it is missing.

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
