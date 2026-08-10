---
type: reference
title: The palette
description: Surface conventions and the verb set — what is built (execution core, pty, store, front door) and what is deferred.
tags: [machteld, palette, verbs, reference]
timestamp: 2026-07-09
---

# The palette

## Surface conventions

- **Namespace + bare verbs:** every command is `::machteld::<verb>`; the prelude also exposes them unqualified (via `namespace path`) so scripts read like a shell — without shadowing any core Tcl command.
- **Options:** Tcl-classic `-flag value`, with a `--` guard separating machteld's options from the external command's args.
- **Values:** durations carry an explicit unit (`500ms`, `30s`, `5m`, `2h`) — a bare number is **rejected**, so `-timeout 100` can never silently mean 100 seconds. Byte sizes take `K`/`M`/`G`.
- **Results:** a dict. `run` returns `{exit status out err pid truncated}` (`status` ∈ `ok` / `error` / `timeout` / `killed` / `running`). Only `child wait` can answer `running` — see [the two timeouts](#the-two-timeouts-and-only-one-of-them-kills).
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

```tcl
run -inherit -- rg -n TODO .   ;# the child gets OUR terminal: colours, pager, Ctrl-C
```

**`-inherit` hands the child our stdio instead of a pipe.** Every other launch path here exists to
*capture*; a front door needs the opposite, because `rg` should colour its output and a pager
should page. Nothing is captured, so `out` and `err` come back empty and the result dict keeps its
documented shape — the same bargain `-channels` makes, and exclusive with `-onout`, `-onerr` and
`-stdin` for the same reason: there is no pipe of ours for a callback to read.

It needed no change in the launcher. `wj_launch` duplicates whichever handles it is given into
inheritable copies and restricts inheritance to exactly those, so handing it the parent's console
handles gives the child the terminal with **every supervision guarantee intact** — born in the job
object, tree-killable, capped, and its deadline still enforced. A stream with no handle (a GUI
process has no console) falls back to `NUL` on its own rather than failing the launch.

(Runtime semantics — linear + bounded lifetime — are in the [execution model](execution-model.md).)

### The two timeouts, and only one of them kills

They look alike and mean opposite things:

| | |
|---|---|
| `child start -timeout 10m` | a **contract the child is launched under**. On expiry it is tree-killed and `status` is `timeout` — settled whenever the child is *observed*, so `child info` enforces it just as `child wait` does, and a supervisor polling every 250 ms caps within 250 ms. |
| `child wait $c -timeout 200ms` | only **how long the caller will stand there**. On expiry the child is untouched and the dict says `status running`, `exit` empty. |

When both apply the **earlier wins**, and what expiry *means* follows from which one it was: a child
given 10 minutes at start does not get more because somebody waited generously, and a caller who
waits 200 ms has not sentenced anything.

That makes a bounded wait safe to poll with, which is what a Tk supervisor needs:

```tcl
proc tick {} {
    foreach c [child list] {
        if {[dict get [child wait $c -timeout 50ms] status] ne "running"} { harvest $c }
    }
    after 200 tick                                ;# the window stays alive throughout
}
```

*It did not always. `child wait -timeout` used to tree-kill on expiry — so the loop above, which is
the pattern this document recommends, quietly killed every child it asked about. Found by building
a supervisor that needed exactly this.*

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
mtps list                            ;# every process on the box: a list of dicts
mtps info 4796                       ;# one of them
mtps kill 4796                       ;# terminate it
mtps kill 4796 -tree                 ;# and everything it started
```

A row is `{pid ppid name exe mem private cpu threads started access}`. `mem` is the working set
and `private` the private commit, both in bytes; `started` is Unix epoch seconds, so
`clock format` reads it directly; `threads` is the thread count.

**This is the half `child` is not.** `child list` enumerates the processes *machteld started* and
holds them in a job object, so `child kill` is exact. `mtps` reaches everything else — and pays for
it in precision: `mtps kill -tree` walks a single snapshot, so a tree that is still forking can
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

`mtps kill` raises `denied` for a process you lack the rights to end, and `notfound` both for a pid
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

## Built — storage

```tcl
store open db.sqlite ; store put k v ; store get k ; store keys ; store del k ; store version ; store close
store open                            ;# no path: an in-memory database, gone when you close it
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

**A write failure never throws.** This is the decision the rest hangs on. A process started
with **no standard channels** — a GUI host, a detached child — makes `puts stderr` raise — and a log call that can
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
the same work in-process — at *that* item size the protocol is nearly free. It is not free at every
size: width 1 over 45 KB file digests costs **0.38×**, because a 159 µs round trip against a
quarter-millisecond of work is most of the work.

**Two numbers decide whether to reach for a pool at all**
([the study](parallel.md#what-the-pool-is-actually-worth--four-arms-measured)):

- **Per item, ~1 ms and up.** Below that the round trip is a real fraction of the work; at 0.5 ms
  the pool still wins (1.64×) but a spawn-per-item loop is 41× worse and in-process is better still.
- **Per job, about four seconds.** Twelve workers cost a few hundred milliseconds to raise. A
  one-second job collects two thirds of the available speedup; by four seconds the startup is paid
  and it plateaus at **~3.2×** on this box, where it stays through at least 32 seconds.

Against a hand-written static partition — twelve children, one slice each — the pool buys **no
throughput**, it matches it (3.21× against 3.17×). What it buys is not having to write the
partition, item costs that are unpredictable or arrive clustered (**2.18× against 1.50×** when the
expensive items sit together), supervision, and a director that is not blocked in `child wait`.

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
makes a **persistent** worker possible: the **44.5 ms** a machteld child costs to start is paid
once rather than per item, and a round trip costs about **159 µs**. It is exclusive with capture — one pipe cannot have
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

**A handler body is compiled in the namespace where you wrote it**, so it reads like the code
around it and calls that namespace's own procs by bare name. The ordinary rule therefore applies
to handlers exactly as it applies to every other line in the file — a namespace of your own needs
`namespace path ::machteld` for bare palette verbs, and at global scope, which is what a small
worker script uses, both resolve with nothing declared.

## Built — the workspace front door

```tcl
front roots                        ;# where the workspace is, and which dir was found
front which rg                     ;# C:/dev/.mt/t/rg/rg.exe
front env rg                       ;# exe, args, env, cwd -- everything, as a dict
front env rg -json                 ;# the same, on the wire
front tools ?pattern?              ;# what the workspace curates
```

machteld is becoming the front door to the workspace it lives in ([the plan](front-door.md)):
one exe at `C:\dev\mt.exe` that turns a **name** into something runnable under a controlled
environment. Resolution is **builtin, then curated tool**, and there is deliberately
**no system-`PATH` fallback** — what runs is what the workspace vendored, not what happens to be
installed on the machine.

The inventory is not this verb's: it is read from the workspace's own `manifest.json`, so while
two front doors exist they cannot disagree about what a name means. Every resolution carries
`MT_ROOT` and `MT_HOME`, plus `MT_PROJECT_ROOT` and `MT_PROJECT_NAME` when the working directory
is inside a project — and the `Z_` spellings as well for as long as the workspace's private
directory is still `.z`, so scripts written against the Go front door keep working.

```tcl
front run -- rg -n TODO .          ;# resolve, run, and hand back the output as a dict
front run -inherit -- rg -n TODO . ;# resolve, run, and give the child the terminal
```

`--` ends `front`'s own options, the same guard `run`, `child start`, `pty spawn` and `detach`
take. It is optional here — only the word directly after `run` is ever read as an option — but
without it nothing on the line says whether `-n` belongs to `front` or to `rg`.

**Two ways to run it, because a front door has two audiences.** A person at a prompt wants the
terminal handed over — colour, a pager, Ctrl-C — while an *agent writing a Tcl script* wants the
output back as data to parse. Capture is the default, since a script is the case that needs a
value returned; the argv dispatcher passes `-inherit`, since a terminal is the case that needs the
terminal. Either way the child is supervised: born in the job object, tree-killable, dying with
this process.

**A builtin runs in-process.** Re-spawning this exe to reach a verb it already has would pay 44 ms
of process start to call a loaded command and hand the answer back through a pipe as text.

**And the exe dispatches its own argv**, so `mt rg -n TODO .` works. The rule, applied in the
prelude because `Tcl_Main` calls AppInit before it reads argv: no arguments is the shell; a
leading `-` belongs to Tcl; something that *looks like a path* (a separator, or a `.tcl`
extension) is a script; anything else is a name to resolve. Deliberately **not** "if the file
exists" — that would let a stray file in the working directory change what `mt rg` means, which is
a PATH fallback wearing different clothes. An unknown name exits **127**, the shell's convention.

**Read-only? No longer, and it still refuses rather than guesses.** A manifest entry using a key the
front door does not implement yet (`preFromRoot`, `pre`, `envFromRoot`, `arg0`) is an *error*,
not a silent partial answer: the point of this stage is to be compared against `z`, and a
confident wrong resolution is worse than a refusal that names what is missing.

## Built — the front door's record

```tcl
front journal                      ;# open the workspace's record -> its path
front projects ?-json?             ;# the hosted _projects
front runtimes ?-json?             ;# the payloads under .z/r, and what aliases them
front status ?-json?               ;# root, workspace git, every project's git
journal rows -live                 ;# what is running now
journal rows -limit 20             ;# the last 20, newest first
journal rows -name rg -project els -since $ms -failed
journal stats                      ;# counts by status, and the row total
journal prune $cutoffMs            ;# drop what is older than a cutoff
```

A front door sees every process the workspace starts, which nothing else does — a shell records
the line you typed, not what it resolved to, how long it took, or whether it was killed.
`front run` records around every spawn, so the record accrues without anyone remembering to ask.
The reasoning, the schema and what is deliberately absent are in [the journal](journal.md).

## Built — a tool of your own, with no compiler

```tcl
wrap ./mytool -o mytool.exe --gui       ;# a windowed tool, one file, no install
wrap ./mytool -o mytool.exe --console   ;# a command-line one
```

`<tooldir>` holds the tool's Tcl, entry point `main.tcl`. Out comes **one exe that is the tool**:
the Tcl/Tk script libraries, the whole [palette](#), and the tool's own files, appended onto a bare
host with `zipfs lmkimg`. Nothing is compiled — the hosts ride inside `mt.exe` already
([packaging](packaging.md)).

**What it is for**, stated plainly because it is the thing that justifies the weight: you write a
small tool in an afternoon and a colleague needs to run it. They have no Tcl, no Python, no install
rights and no patience. `wrap` hands you a single file to drop on a share. That is the receiver —
and it is exactly the one an earlier refusal of this feature said did not exist, which is why the
[register](direction.md) now records it by name.

**Two subsystems, because Windows compiles the choice in.** `--gui` stamps onto the `-mwindows`
host so a windowed tool shows no console; `--console` stamps onto the `Tcl_Main` host so a
command-line tool has real stdio. It is not a PE byte-flip: a console host running in a GUI
subsystem has no valid standard channels and `puts stdout` throws *"can not find channel named
stdout"*.

**It costs the front door about 13 ms**, and the first number published here said 130 — see
[the log](log.md) for the correction. Carrying both hosts makes `mt.exe` 10.2 MB instead of 6.0,
and a same-session A/B of the two builds puts the difference at ~13 ms of the ~25 ms `mt version`
costs in total. Cheap, and worth it for one file that stamps anywhere.

## Built — naming a script

```tcl
tcl app.tcl arg1 arg2              ;# this process becomes app.tcl
```

**The first argument to `mt` is a name. Always, with no test of any kind.** Until 2026-08-10 the
dispatcher handed anything that *looked like* a path — a separator, or a `.tcl` extension — back to
`Tcl_Main` as a script, so `mt app.tcl` ran app.tcl the way `tclsh app.tcl` does. That was never
"does this file exist", which would have let a stray file change what `mt rg` means. It was still a
**shape test**: a heuristic guessing which of two kinds of thing you meant from how you spelled the
word. The case it could not answer is `mt rg` standing next to a file called `rg` — and there are
273 curated names for such a file to be named after.

So a script is named now, and the dispatcher has no heuristic left in it:

```bash
mt tcl test/run_test.tcl
```

That cost a word at 71 call sites in this repo, once. What it bought is a rule one line long, which
is [the creed](creed.md)'s *determinism over cleverness* applied to the last place the front door
was still guessing.

**`tcl` does not return, and that is the point.** The process *becomes* the script: its `argv0`,
its `argv`, its event loop, its exit code. To **include** a file in the program you are already
running, that is Tcl's own `source`, and always was. The two are different acts and now have
different names.

**It runs the event loop, because `Tcl_Main` no longer will.** Under `tclsh`, `package require Tk`
hands `Tk_MainLoop` to `Tcl_SetMainLoop` and `Tcl_Main` runs it *after* the script returns — so a
windowed program that never calls `vwait` still works. Sourced from the prelude with nothing after
it, that same program builds its window, returns, and the process dies before one event is
dispatched. `tcl` waits on the main window instead, which is the same loop for a program that has
one.

**Typing the old spelling tells you the new one.** `mt app.tcl` now names a tool nobody curates, so
it exits 127 — but if what you typed looks like a filename, or is one, the second line of the error
says `mt tcl app.tcl`. That check is the one place `file exists` appears; it is in the *message*,
never in the decision, so what `mt` runs still cannot depend on what happens to be in the working
directory.

**`front journal` is how a reader gets in.** `journal` itself takes a path, and the recorder opens
it lazily, so a script that only wants to *read* would have had to spell the filename — a second
authority on where the record lives. This opens the same file and returns its path. Unlike the
recorder, it does not swallow failure: a script asking for the journal wants to be told when there
isn't one.

**Its own connection and its own file** (`$MT_HOME/mt.db`), separate from `store`: one is a
key/value surface over a database a script chose, the other is the front door's own record, and
neither should be able to evict the other by both being "the" database.

**Still no raw SQL.** `store` says it plainly and that refusal holds here: every statement is
written out in the C and every caller value is **bound**, so a tool named `x'; DROP TABLE run; --`
is a tool name and not a fragment of a query — which the suite checks by storing exactly that.

**Recording never breaks the command it records.** No workspace, an unwritable directory, a
database from a newer build: each is a reason the journal is off, and none is a reason a tool
should refuse to run. The same bargain [`log`](#) already makes.

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

Every program machteld ships needs argument parsing, and every one used to write its own. A name
beginning `--` is an option, anything else is a positional taken in declaration order, and `--`
ends option parsing. Attributes: `type` (`flag` / `int` / `string`), `default`, `min`, `max`,
`choices`, `required`, `help`.

**It prints nothing and never exits.** An `argparse`-style "print usage and exit" is invisible
exactly where it matters most: a program with **no standard channels** cannot report, so a tool
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

The bug it removes is real, and it is why the two codes are separate. A Tk task manager built on
this palette took `--interval` with nothing after it, set the interval to the empty string, and
`after ""` then threw out of the refresh timer — killing the tool at startup, or worse, stopping a
running one from refreshing while it still showed a list that looked live. A missing value is
refused where it is missing now.

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

None of these is scheduled. `watch` and `mtps` both arrived because a tool asked — the
change-viewer needed live file events, the task manager needed a view of processes machteld did
not start — and that remains the best reason to build one, because it is also when the dict shape
stops being a guess. It is no longer the *only* reason: [rule 5](direction.md) was rewritten on
2026-08-09 to allow building a domain to find out what it wants to be. What holds instead is that
nothing is frozen before 1.0.0 anyway, so a shape built to find out is free to change once you
have found out.
