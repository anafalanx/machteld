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
run -arg0 make -- mingw32-make.exe -C $dir   ;# the child reads `make` as its own name
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

**`-arg0` renames the child without redirecting it.** A program's `argv[0]` is not always where it
lives: the workspace vendors GNU Make as `mingw32-make.exe`, and a makefile asking `$(MAKE)` — or a
recursive build re-invoking itself — reads back whatever `argv[0]` said, so under its real filename
every recursion spells the tool wrong. Declared by the *shared* option parser, which is why `run`,
`child start`, `detach` and `pty spawn` all take it: all four spawn, and that parser is the one
place a spawning option belongs.

It is applied **after** the program is resolved from `argv[0]` as written, and that order is the
whole safety property: `-arg0` changes what the child calls itself and never which file is found.
`run -arg0 bash -- no_such_program.exe` still fails `notfound`, and the suite checks exactly that —
otherwise a rename would quietly become a `PATH` lookup for something else, which is the one thing
this workspace refuses everywhere.

This one needed no launcher change either, and for a sharper reason than `-inherit` did: `wj_launch`
has always handed `CreateProcessW` the executable and the command line as **separate** arguments
(`lpApplicationName` and `lpCommandLine`). Which file runs and what it calls itself were independent
from the first day — there was simply no way to say so.

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

## Built — the directory tree

```tcl
dirs C:/dev                          ;# every directory beneath it, as a dict
dirs $d -depth 2                     ;# the root is depth 0; -depth 0 is the root alone
dirs $d -prune {node_modules .git}   ;# listed, not descended -- string match, case-insensitive
```

The result is `{root paths dirs links errors pruned depthlimited maxdepth}`. `paths` is the list,
in depth-first pre-order with siblings ascending; `dirs` is how many were emitted (`llength
$paths`); `maxdepth` is the deepest level reached. **Files are never listed** — this verb answers
one question.

**This verb exists because the Tcl version was written three times and was wrong three times,
silently.** `glob -types d *` came back 786 directories short, `glob -- * .*` came back 16,504
over, and deduplicating the second lost the first 786 again — no error from any of them, and the
only reason anyone knew is that the whole list was diffed against another walker's. See
[direction](direction.md), "`cdirs` does not become Tcl". What `glob` actually misses is the
**hidden attribute**, not dot-names — `.git` is `+h` — and `-types {d hidden}` is an *exclusive*
filter that returns the hidden entries only.

**So the shape of the answer is arithmetic, not prose.** Every directory under the root is either
in `paths`, or its absence is attributable to exactly one counted cause: an ancestor in `errors`,
an ancestor counted in `pruned` or `depthlimited`, or a `links` row saying the walk stopped at a
name standing for somewhere else. Nothing can go missing without a row that says so.

- `links` — one dict per directory reparse point encountered, `{path tag surrogate action}`,
  where `action` is `descended`, `nofollow`, `pruned`, `depthlimited` or `failed` (the descent was
  attempted and the open failed — there is an `errors` row beside it).
- `errors` — one dict per failure, `{path win32 reason}`. The raw Win32 code travels with the
  message because the message cannot be trapped on and does not discriminate: a directory pending
  delete and an ACL denial both arrive as `ERROR_ACCESS_DENIED`. **An unreadable subdirectory is
  a row, never an exception** — it is still listed, since we saw it in its parent. **One row per
  lost directory**, not per parent, so the cardinality is recoverable and the arithmetic above can
  actually be closed.

`pruned` and `depthlimited` **count refusals, not elisions.** Every directory not descended is
counted, including a leaf with nothing underneath it — so `depthlimited == 0` is the only reading
that means "nothing was cut", and a nonzero value is not the number of omitted subtrees.

**Only *name surrogates* are refused entry, which is a deliberate difference from `z cdirs`.** A
junction is tag `0xa0000003` and a symbolic link `0xa000000c`; both set the surrogate bit
`0x20000000` and both are genuinely another name for somewhere else. A OneDrive Files-On-Demand
root is `0x9000701a` and does **not** — it is ordinary content behind a filter, and refusing to
descend it omits everything beneath it. The bit is the usual *spelling* of "a name for somewhere
else" rather than the rule itself, so DFS (`0x8000000a`) and DFSR (`0x80000012`) are refused
beside it although they do not set it: they redirect into another namespace, and one pointing back
at an ancestor is a cycle this veto would otherwise not bound. That pair is reasoned from the
tags' documented meaning and **not** measured — there is no DFS namespace on the machine this was
built on.

Every reparse directory gets a `links` row carrying its tag, so the choice is auditable rather
than asserted — **including when the reparse point is the root you named.** A junction root is
descended (you named it, so you get it) and its row says `{surrogate 1 action descended}`, which
is the only thing in the answer disclosing that every path returned is a second name for a tree
living somewhere else. The classification is made on a *handle* opened with
`FILE_FLAG_OPEN_REPARSE_POINT`, not on the parent's directory scan, so a name replaced between
enumeration and descent cannot walk the walker out of the tree.

**Long paths work.** Every path is `\\?\`-prefixed internally; without that, seven directories in
`C:\dev` at lengths 278–424 vanish with a clean exit. Paths come back forward-slashed and
unprefixed, and a UNC root round-trips as `//server/share/…`. `C:/` and `\\?\C:\` are both the
drive's root *directory*; `\\?\C:` would be the volume device and is never built.

**A root component ending in `.` or a space is refused, not honoured.** Win32 normalisation trims
both, so `dirs X/...` would resolve to `X` and hand back the *parent's* tree under the parent's
name — a clean, plausible answer to a question nobody asked. `.` and `..` are exempt, since there
the trailing dots are the whole meaning. The walker lists such directories happily, so this is one
place its own output does not round-trip: spell the root `\\?\C:\…`, which turns normalisation off
and reaches them.

`-depth 0` is the root alone and **never** means unlimited — unlimited is spelled by leaving the
option out, because a sentinel that turns a typo into a thousand-fold difference in what you get
back is the same mistake as `-timeout 100`. A drive-relative root (`C:` rather than `C:/`)
resolves against the per-drive current directory, which is process state nobody set; it is
refused with `badvalue` naming the spelling that works.

### `links` — the same walk, asked a different question

```tcl
links C:/dev                         ;# every name surrogate under it, with where it points
links $d -hardlinks                  ;# and every file whose bytes are shared
links $d -depth 2 -prune {node_modules}   ;# the same two options dirs takes
```

The result is `{root links multilinked dirs files errors pruned depthlimited maxdepth}`. `links` is
one dict per name surrogate — `{path type target tag}`, where `type` is `junction`,
`file symlink` or `directory symlink` — and `multilinked` is one dict per file with more than one
name, `{path links}`, empty unless `-hardlinks` was asked for.

**The two questions `mirror` asks of a tree before it will touch it**, and they are one verb
because they are one walk. `dirs` throws every file entry away at the moment the enumeration hands
it over, tag and all; `links` keeps it. Measured, that costs nothing: 986 ms against 1,013 ms over
302,654 entries, because the bytes were already in the buffer. See
[spike/mirrorlinks](../spike/mirrorlinks/RESULTS.md).

**`-hardlinks` is an option and not the default because it is the one thing the enumeration cannot
answer.** No directory info class carries a link count, so it costs one open/query/close per file
— ~66 µs, against ~3.3 µs per entry for the whole walk. Directories are never opened for it: NTFS
does not permit hardlinks to directories, so their count is always 1, and a handle-per-entry scan
takes 2,523 more handles than a handle-per-file scan over `.z\r\msys2` and finds exactly the same
160 multilinked files. Reparse points are not opened either — their bytes are a link payload, not
shared content.

**The type names are z's, deliberately**, because they are written into the restore manifest a
`mirror` replica carries: a file format shared with the front door being replaced, not a rendering
choice. Same reasoning as the ledger's `generatedBy`.

**A surrogate this verb cannot name, or whose target it cannot read, is an `errors` row** as well
as a `links` row with the field left empty. That is what lets `mirror` refuse a destructive run
rather than write a restore manifest that silently omits a link — the refusal is reached from the
same facts z reaches it from.

`links` follows the same descent policy as `dirs`, so the root exemption applies here too: a
junction root is walked, and reported.

### `canon` — which object is this path, and where does it really live?

```tcl
canon C:/dev/.z/r/winsdk/10.0.26100.0
    → {path "C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64"
       volume 00000000eb960d30  file 00060000001cd001  kind directory  links 1}
```

One open that **follows**, and two questions asked of that handle:
`GetFinalPathNameByHandleW` for where the object is, `GetFileInformationByHandle` for which object
it is. `path` comes back forward-slashed and unprefixed like `dirs`'s; `volume` and `file` are
16-digit hex tokens to compare rather than numbers to do arithmetic on, because a 64-bit file index
does not fit a signed wide.

**This exists because Tcl gets both halves wrong, and gets them wrong quietly.** `file normalize`
does **not** resolve a reparse point that is the *final* component — measured on the junction above,
it returns the junction while normalising one component deeper follows it. And `file stat`'s `dev`
is the **drive-letter index** (every path on `C:` reports 2, where the volume serial is
`0xeb960d30`), while on a junction it describes the junction rather than its target. Two names for
one file do share an `ino`, so a caller comparing identities gets self-consistent answers that are
about the wrong objects — the most dangerous shape a wrong answer can take.

`mirror` is the caller that needed it: a destination junction pointing into the mirror source passed
every containment clause, and robocopy's own `/L` verdict then named a file *inside the source* as a
destination extra. See [the front-door plan](front-door.md).

**The numbers are z's numbers.** `volume` and `file` are the same `dwVolumeSerialNumber` and 64-bit
file index z hashes into its mirror-state filename, verified by computing the key here and finding
z's own artefact index already sitting at that name.

- `dangling` is its own error code, not `notfound`, and the distinction is load-bearing: a resolver
  walking up to the nearest existing ancestor must treat *nothing here* as "keep going" and *here,
  but broken* as "stop". `file exists` cannot tell them apart — it answers **true** for a dangling
  junction — which is why mirror's first attempt at this test was dead code.
- `links` is the file's hard-link count, free from the same call.

**What it deliberately does not do**, because [rule 4](direction.md) says C is for what Tcl cannot
reach: it does not write the list to a file (three lines of `open`/`puts` do that, and a result
key that is silently empty whenever an option is used is the failure this verb exists to abolish),
it does not call back with progress, it does not report an elapsed time (`clock milliseconds`
either side of the call is the same number), and it does not resolve links to their targets — that
is canonicalisation, containment, identity and a `seen` set, which is a subsystem rather than a
verb.

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
front door does not implement is an *error*, not a silent partial answer: the point of this stage
is to be compared against `z`, and a confident wrong resolution is worse than a refusal that names
what is missing. `preFromRoot`, `pre`, `envFromRoot` and `arg0` are all implemented now — **every
key the workspace manifest uses is honoured**, and there is nothing left on that refusal list.

`arg0` was the last, and it is worth saying why it took a C option to close. One tool asks for it:
`make`, which the workspace vendors as `mingw32-make.exe` and which must read `make` back from its
own `argv[0]`, or a makefile asking `$(MAKE)` — and every recursive build — gets the wrong spelling.
The refusal was correct while the palette had no way to express it and wrong as a permanent state,
because `mt make` simply did not work. The launcher needed no change at all: `wj_launch` has always
handed the executable and the command line to `CreateProcessW` **separately**, so which file runs
and what it calls itself were independent from the first day. See [`-arg0`](#built--execution-core).

## Built — the front door's record

```tcl
front journal                      ;# open the workspace's record -> its path
front projects ?-json?             ;# the hosted _projects
front runtimes ?-json?             ;# the payloads under .z/r, and what aliases them
front status ?-json?               ;# root, workspace git, every project's git
front in els build                 ;# resolve and run a name in a project's context
front verify ?-json?               ;# the workspace's structural problems
front scout ?-commands? ?--serial? ?-json?   ;# every _dir: project file, readme, git, commands
front ledger refresh               ;# rewrite book/*.lock.* from what is on disk
front ledger check                 ;# does the tree still match the ledger? exit 1 if not
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

**`verify` and `ledger check` report a verdict, so they set an exit code.** Both return their text
as a value like every other command, and both additionally say what the *process* should exit with
— 1 when there is something to report. That is not an error and is deliberately not raised: a
command that looked and found problems ran successfully, and a script that `catch`es it would treat
a working command as a broken one. `mt verify` exited 0 on a workspace with five problems until
2026-08-11, which is what forced the mechanism; see [the front-door plan](front-door.md).

**`ledger`'s output is a file two programs write**, so it is byte-identical to z's down to Go's
`json.MarshalIndent` quirks — HTML-escaped `&`, struct field order, and a `"restore": {}` on every
payload because `omitempty` does nothing to a struct. `generatedBy` still names z for the same
reason: it identifies the format, and a second implementation of a format is not a second format.

## Built — the directory index

```tcl
front cdirs                        ;# the workspace, to $MT_HOME/cache/mt/dirs/<slug>.txt
front cdirs C:/Users/anafa         ;# any root you name
front cdirs $d -depth 3 -prune {node_modules .git}
front cdirs $d -out list.txt       ;# a file of your choosing, report beside it as list.json
front cdirs $d -stdout             ;# paths on stdout, report on stderr, no files at all
front cdirs $d -json               ;# the report as JSON instead of as text
```

`cdirs` is [the `dirs` verb](#) with the policy on top: C for the walk, Tcl for where the answer
goes and what it means. It is a **front-door command**, so `mt cdirs` works as a bare name, and it
is the command `z cdirs` is being replaced by.

**One positional and four options, where z has twelve.** The root is a positional because that is
how `dirs` spells its own subject, and a command built over a verb must not respell the verb's
grammar. Gone, each for a reason: `--slash` (there is one spelling, and it is forward), `--tree`
(a second output grammar that cannot be grepped, cannot be diffed, and has nowhere to put the
disposition markers this command exists for), `--safe` (z's own help calls it a no-op),
`--follow-links` (the verb has no descent-policy lever, and building one in the prelude means
canonicalisation, containment and volume+file-id identity — a subsystem), `--flush` (nothing is
written until the walk is complete), `--progress` (the verb reports none, and the honest
consequence is stated below), `--quiet`, `--gc`, `max stack` and `outside root`.

**And no `-cloud` / `-nocloud`.** It would be a switch whose only purpose is to reproduce the
behaviour measured below as wrong — and, decisively, it *cannot be built here*: skipping is a veto
**inside** the walk, the verb exposes no hook for one, so a Tcl-side `-cloud` could only
post-filter a list it had already paid the full 22 seconds to build. A shorter answer at full cost,
wearing the appearance of a skip.

**`-prune OneDrive` is a way to skip a place cheaply, and it is not a way to get z's answer.** The
veto is in the verb and the time is genuinely saved — 8.2 s against 22.4 s on the home tree — and
the report gives the **count** and the **patterns**, which is all the verb offers. What it does not
do is reproduce z, and both directions of that are worth writing down because only one of them is
obvious. It matches a **name** and not a tag, so a tenant folder called `OneDrive - Contoso` is
*missed* without `-prune {OneDrive*}` — and on this machine the *over*-match is what actually
fires. Measured: `-prune OneDrive` hits **four** places, not one —

```
C:/Users/anafa/OneDrive
C:/Users/anafa/AppData/Local/OneDrive
C:/Users/anafa/AppData/Local/Microsoft/OneDrive
C:/Users/anafa/AppData/Local/Microsoft/Office/SolutionPackages/.../assets/assets/onedrive
```

— so the answer is 111,899 directories against z's 112,015, and it is not a subset: it **drops 126
directories z lists**, 124 of them the entirely unrelated `AppData/Local/Microsoft/OneDrive`
subtree. There is no option here that reproduces z's descent policy, and none is planned; z ships
`--follow-links` as its lever in the opposite direction and machteld ships none in either.

A pruned reparse directory is a refusal the **caller** asked for, so it is counted and not named,
and `"entered":[]` after `-prune OneDrive` is correct rather than a lost disclosure: naming it
would put one place in two accounts and break the arithmetic below. The caller who typed the word
already knows.

**The default root is the workspace, not `C:/`, and that is a deliberate divergence from z.** The
front door's subject is `MT_ROOT` — `tools`, `projects`, `scout`, `verify` and `status` all answer
about it without being told — and a bare `mt cdirs` walking the whole drive would be the only
front-door command silently widening past the workspace, at the highest cost in the set. The
argument that actually decides is that a default should be the root where the answer is
*checkable*: on `C:/dev` machteld and z agree exactly, 21,804 against 21,804 (an active build tree,
so the number itself moves between runs; what does not move is that the two agree both ways); under
`C:/` they disagree by design. Making the wide walk something you opt into by naming it puts the
disagreement in a request somebody typed.

**The default output path is `$MT_HOME/cache/mt/dirs/<slug>.txt`, and never z's.** During the
transition `MT_HOME` *is* `.z`, so writing to `cache/cdirs/c-drive-dirs.txt` would overwrite the
live cache of the front door still in daily use — with a forward-slashed list that is also scoped
differently. z's fixed name means `z cdirs --root C:\dev` writes the workspace into a file called
`c-drive-dirs.txt`, overwriting the drive index.

**The slug is derived from the normalised root, and it says when it could not be.** `C:/dev` →
`c-dev`, `C:/Users/anafa` → `c-users-anafa`, `//srv/share/x` → `srv-share-x`. The squash to
`[a-z0-9]` is **many-to-one**, so it is only used where it is reversible: the name is reconstructed
back into a root, and if that does not reproduce the root exactly the file gets an
`--<8 hex of sha256>` tail instead — `C:/dev/_x`, `C:/dev-x`, `C:/dev.x` and `C:/dev x` therefore
key four different files where they once keyed one. A slug over 64 characters is truncated and
gets the same tail. **Two different roots cannot collide**, and that sentence is load-bearing
rather than decorative: it shipped false, and two genuine pairs were already colliding among the
real indices on this machine (`.codex/.tmp` against `.codex/tmp`, `OneDrive/_LIVE` against
`OneDrive/live`), while any root whose last component is entirely non-ASCII squashed to its parent
and overwrote it.

**The report is written beside the list, always, as `<name>.json`.** It is the whole report rather
than z's errors-only sidecar, so its presence is unambiguous — z creates its `.errors.txt`
unconditionally and mentions it only sometimes, which makes absence mean either "clean" or "the
run died". The list file stays pure paths, one per line, UTF-8, LF, no BOM and no header, because
a header stops it being greppable.

**A present report means the list beside it is whole.** Both files are written to `.tmp` and
renamed; the old report is moved aside rather than deleted, so a publish that cannot replace the
list puts it back and the previous run survives intact, and a publish that replaces the list but
cannot write the report leaves the report **absent** rather than stale — a report describing a
list it was never a report of is the one state the ordering exists to make impossible. A walk that
raises writes nothing at all rather than replacing a good cache with a short one. `-out` naming an
existing **directory** is an `oserror` and not a success, and so is a directory standing where the
`<name>.json` sidecar would go: `file rename` moves a file *into* a directory target, and the
sidecar's publish step would otherwise remove whatever stood in its way.

### What the report says, and why z's line is not enough

> A refusal the **walker** made is NAMED. A refusal the **caller** asked for is COUNTED. And the
> completeness verdict is on the first line, beside the count, so the count cannot be read alone.

Real output, `mt cdirs C:/Users/anafa`, with nine of the eleven junction rows cut for width and
nothing else altered:

```
cdirs [PARTIAL]  236,169 directories under C:/Users/anafa in 24.7s
list             C:/dev/.z/cache/mt/dirs/c-users-anafa.txt  (22.3 MB)
report           C:/dev/.z/cache/mt/dirs/c-users-anafa.json

refused          11 places. The walk stopped at each; what is inside is not in
                 the list, and how much is there cannot be known from here.
  junction       C:/Users/anafa/PrintHood
  junction       C:/Users/anafa/Recent

entered          1 reparse directory that is content, not a second name for
                 somewhere else, and everything under it IS in the count above.
  cloud          C:/Users/anafa/OneDrive                            tag 0x9000701a
                 124,144 of the 236,169 directories above -- 52.6% of this answer -- are under it
```

The total moves between runs — a home tree churns, and 236,159 / 236,169 / 236,162 are three real
answers within an hour. The 124,144 under the cloud root did not move in any of them.

**Named rather than counted, because for `refused` the number cannot be had.** The size of what
lies behind a place the walk did not enter is not knowable *without entering it* — that is what
not entering means, not a gap in the implementation. So the one honest disclosure available there
is the **place**, and it is affordable exactly where it matters: eleven such places in the whole
home tree, two in the workspace. z's line says `12 links skipped` and names none of the twelve; on
this machine one of them hid 124,144 directories and the other eleven hid a few hundred between
them, and the integer cannot tell them apart.

**Named *and* counted for `entered`, because there the number CAN be had, and this is where the
first version of this command repeated z's mistake with the terms swapped.** The walk *did* enter,
the paths are in hand, and a prefix count over them is sub-second against a twenty-second walk. A
row that says only `cloud  C:/Users/anafa/OneDrive` is true and hides that **half the answer came
from that one line** — *named, magnitude invisible*, which is worth exactly as much as z's
*counted, consequence invisible*. Every `entered` row therefore carries `below`, in the text and in
the JSON.

**And the completeness sentence is conditional.** `everything under it IS in the count above` is
printed only when nothing was pruned, no `-depth` cut fired, and no refusal lies below that row;
otherwise it says what is under it is only *partly* in the count. Unconditional, it was false on
every `mt cdirs C:/Users/anafa -depth 3` — telling the reader the list is complete below a place
where ~124,000 directories are missing, which is the one direction this command exists to prevent.

**Counted rather than named for `-prune` and `-depth`**, because the caller already knows the
criterion, and because the verb offers integers there and not path lists. The wording does not
overclaim: those *count refusals, not elisions*, and a leaf with nothing under it is counted too.

**A reparse directory the walk ENTERED is disclosed as well**, since the reverse silence is just as
possible: a reader expecting z's semantics gets more than twice the lines and no way to learn why.
A descended *surrogate* can only ever be the root you named, and it gets its own block saying so —
every path in that answer is a second name for a tree living somewhere else, which is precisely
the disclosure `dirs`'s own review found missing from the verb.

`COMPLETE` requires `refused`, `pruned` and `depthlimited` all empty or zero; anything else is
`PARTIAL`. The verdict is deliberately conservative — a depth-limited walk whose cut points are
all leaves reports `PARTIAL` although nothing was lost — because for a cache index "you may not
have everything" is the safe direction to err in. **`PARTIAL` still exits 0**: every walk of any
real tree refuses something, so a nonzero exit would fire on essentially every invocation and
train exactly the reflex this report is fighting. A script that cares reads `complete` from the
JSON.

Tag naming is policy, so it is Tcl: `junction` `0xa0000003`, `symlink` `0xa000000c`, `dfs`
`0x8000000a`, `dfsr` `0x80000012`, `cloud` for the family `tag & 0xffff0fff == 0x9000001a`
(`IO_REPARSE_TAG_CLOUD_1` through `_F`, of which only `0x9000701a` has been observed on this
machine — said out loud for the same reason `dirs.c` says it of its DFS pair), `reparse` for a tag that
reads 0 through a handle, and otherwise the hex verbatim. The table names **only** what `dirs.c`
itself names, because a wider one would be the front door asserting knowledge the C's own veto rule
does not have, and the two would drift with nothing to notice.

**`-stdout` and `-json` are orthogonal**: `-stdout` chooses where the *list* goes, `-json` the
*format of the report*. All four combinations mean something, so there is nothing to refuse.
`-out` with `-stdout` **is** refused — they are two dispositions named at once, and silently
letting one win would be the command ignoring what the caller wrote.

**Three honest costs, stated rather than hidden.** There is no progress output, so
`mt cdirs C:/Users/anafa` prints nothing for ~22 seconds and then prints everything at once. The
list is forward-slashed where z's is backslashed, so **anything reading z's cache file byte-wise
will not read this one** — the other half of why the default path is not z's. And the third belongs
to whoever *consumes* the list: **52.6% of the lines are inside a Files-On-Demand root**, where the
folders are local but some of the files are dehydrated placeholders — 67 of the first 4,000 files
sampled under it carry `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS` (`0x400000`). A backup, an indexer or
a `grep -r` fed this list will touch content that z's list would never have named, and can trigger
downloads. Descending is still right — the folders are real, and z's silence about them is the
defect this command exists for — but "more complete" and "cheaper to consume" are not the same
property, and only the first was ever written down.

**Every timing on this page is WARM**, a repeat walk on the same day. Costs are not labelled that
way by accident elsewhere in this file (`~1-2 s warm` for the workspace) and the omission matters
most here: the OneDrive subtree is precisely the part that is not touched daily, so a first walk
after a boot is materially more expensive than 22 s. A cold first-of-the-day walk was observed at
52 s during review and has not been reproduced here, which is said rather than published as a
figure.

Failures re-raise in `FRONT`, because the domain is the verb you called: `notfound` for a root that
is not there or is not a directory, `badvalue` for a root or option value the verb refuses,
`oserror` for a list or report that cannot be written, `usage` for the rest. The inner message is
kept verbatim — `dirs` says which spelling of a bad root works, and that sentence is the useful
part.

**An empty value is a value, not an absence.** `-depth ""` is refused exactly as `dirs` refuses it,
an empty root is refused exactly as `dirs` refuses it, `-out ""` is refused rather than quietly
becoming the default cache path, and two empty roots are still two roots. All four used to be read
as "not given" — so `mt cdirs $root -depth $limit` with an empty `$limit` became a full walk whose
report did not even record that a limit had been asked for. `-out` must also still name a file
after `..` is resolved: a path that climbs above the root of the drive is a `badvalue`, not a
filename relative to wherever the command happened to be run.

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
