---
type: reference
title: Command palette
description: The public Machteld 0.11.0 commands and their intended composition.
tags: [machteld, api, tcl, windows]
---

# Command palette

All commands are in `::machteld` and resolve as bare names in a top-level entry.
This page is a composition tour. The [complete reference](reference/machteld/index.md)
has the exact command pages; `[manifest]` describes the running build and `docs`
queries the complete embedded Machteld/Tcl/Tk corpus.

## Process control

```tcl
set r [run -timeout 30s -dir C:/work -env {MODE test} -- tool.exe arg]
puts [dict get $r out]

set c [child start -channels -- worker.exe]
child info $c
child wait $c -timeout 5s
child kill $c
child close $c

wait -any $a $b
scope { child start -- server.exe; run -- client.exe }
detach -dir C:/service -- daemon.exe
```

| Command | Contract |
|---|---|
| `run` | Launch and wait. Captures stdout/stderr by default; `-inherit` gives the child the terminal, `-onout/-onerr` stream lines, and `-stdin` supplies input. Supports `-arg0`, `-cpu`, `-mem`, `-dir`, `-env`, and `-timeout`. |
| `child` | `start`, `wait`, `kill`, `info`, `list`, and `close` for supervised asynchronous children. `start -channels` exposes stdin/stdout/stderr channels through `child info`; the caller must close stdin when the child expects EOF. |
| `wait` | Wait for child or filesystem-watch handles; `-any` returns when the first is ready. |
| `scope` | Evaluate a Tcl body and close every child born inside it, even when the body errors. |
| `detach` | Launch an independent daemon and return its PID. Success is verified outside every Windows job; an enclosing policy that denies breakaway raises `{MACHTELD DETACH launch}`. |

Every supervised process launch is born into the host-owned root Job Object and
a narrower per-command job before user code can run. The host owns the root job
without joining it; `detach` joins neither job. Closing or killing a supervised
handle terminates the whole child tree. Use `--` before the child command when
its arguments can look like Machteld options.

A bare command is searched only in `PATH`, never in the current directory. If
it has no extension, Machteld tries `.exe`, `.com`, `.bat`, then `.cmd`; it does
not consult ambient `PATHEXT`. Use an explicit path for any other executable
spelling.

The two child timeouts deliberately mean different things. `child start
-timeout` is a lifetime deadline: Machteld kills the process tree when it
expires. `child wait TOKEN -timeout` bounds only that observation; it returns
`status running` and leaves the child alive when the wait expires.

Channel mode transfers pipe ownership to the caller. Drain stdout/stderr while
the child runs, and close the exposed stdin channel after the final request;
`child wait` observes completion and does not manufacture EOF by closing it.

## Interactive processes

```tcl
set p [pty spawn -- cmd.exe]
pty send $p "echo hello\r"
set answer [pty expect $p -timeout 5s {
    {*hello*} {return matched}
    timeout   {return late}
}]
set raw [pty read $p -timeout 100ms]
puts [pty strip $raw]
pty info $p
pty close $p
```

`pty` wraps ConPTY. Native subcommands are `spawn`, `send`, `read`, `close`,
`list`, and `info`; Tcl adds `expect` and `strip`. `expect` glob-matches an
accumulating VT-stripped buffer and evaluates the selected body in the caller's
scope. `strip` removes CSI, OSC, and common escape sequences without needing a
live terminal. `read` returns immediately by default and waits only when given
`-timeout`.

## Files, links, and events

```tcl
set w [watch start C:/work -recursive]
set events [watch read $w -timeout 2s]
watch info $w
watch close $w

set d [dirs C:/work -depth 3 -prune {.git node_modules}]
set l [links C:/work -hardlinks -depth 3]
canon C:/work/a-junction
```

| Command | Contract |
|---|---|
| `watch` | Live directory events through `start`, `read`, `info`, `list`, and `close`. `read` returns immediately unless given `-timeout`; `-raw` keeps the OS event stream while the default coalesces it. `info` reports token, directory, recursive/armed state, pending/dropped/failed counts, and `win32` (zero unless the watch failed) without consuming events. |
| `dirs` | Deterministic depth-first directory walk. `-depth` bounds descent and `-prune` accepts case-insensitive glob names. Returns counts, ordered paths, link decisions, errors, and completeness facts. |
| `links` | Walk reparse points without following name surrogates; `-hardlinks` also reports files with shared storage. It uses the same depth/prune policy as `dirs`. |
| `canon` | Resolve a path through reparse points to its canonical target; a dangling target is a structured error. |

## Machine processes

```tcl
mtps list
mtps info 4812
set report [mtps kill 4812 -tree]
# report: {killed {4812 9004 ...} failed {{pid 9010 code denied} ...}}
```

`mtps list` returns process dicts for the machine and `info` returns one. `kill`
has exact arity and accepts only optional `-tree`. Tree kill returns a disclosure
dict: every terminated PID is in `killed`, and each descendant that could not be
terminated appears in `failed` with stable code `denied` or `notfound`. A
non-tree failure to open or terminate the single target raises instead of being
hidden in a report. Tree mode is a best-effort snapshot of machine processes;
descendants born afterward and PID reuse can race it. Use `child kill` for a
tree launched and owned by Machteld, where the Job Object provides the stronger
lifetime boundary.

## HTTP, JSON, hashes, and storage

```tcl
set r [http get https://example.com -timeout 10s -maxbody 8M]
set body [dict get $r body]                 ;# bytearray
http post $url [json encode -dict $doc] -type application/json

set doc [json decode {{"name":"x","n":42}}]
json encode -dict $doc

hash sum sha256 $bytes
hash file sha256 C:/large.iso
hash hmac sha256 $key $bytes
hash random 32

store open state.sqlite
store put image $bytes
set sameBytes [store get image]
set names [store keys]
store del image
store close
```

`http` uses WinHTTP for HTTPS, system trust, redirects, proxy discovery, and
transport decoding. `get` and `post` return `status`, cooked lower-case `headers`,
`rawheaders`, bytearray `body`, and `bytes`. Options include `-headers`,
`-timeout`, `-agent`, `-type`, and `-maxbody`. The size limit refuses an oversized
body; it never returns a plausible truncation. A URL fragment is client-side and
is not sent. HTTPS-to-HTTP redirects are refused. There is no insecure TLS option.

`-timeout` uses the exact duration grammar and refuses zero. WinHTTP applies the
value separately to each network phase; it is not a single wall-clock deadline
for the complete redirect/request/body operation. `-maxbody` uses the shared
binary size grammar. When omitted, `-timeout` defaults to 30 seconds per phase
and `-maxbody` to 64 MiB. On `post`, a caller-supplied `Content-Type` header is
kept unless `-type` is explicitly supplied, in which case `-type` wins.

`json decode` builds Tcl dict/list/scalar values and keeps number text exact.
JSON `null` maps to the empty Tcl string and booleans to integers, so those three
values do not round-trip as distinct JSON types. Duplicate object keys keep the
last value. An escaped unpaired UTF-16 surrogate is replaced with U+FFFD.

`json encode` follows a Tcl object's internal dict/list representation;
`-dict` and `-list` force the container reading when needed. A scalar string that
is exactly a JSON number literal encodes as a number. Use `--` when an option-like
scalar must be data: `json encode -- -dict` encodes the string `"-dict"`.

`hash` supports `md5`, `sha1`, `sha256`, `sha384`, and `sha512` through Windows
CNG. `sum`, `file`, and `hmac` return hex unless `-binary` applies. `start`,
`update`, `final`, and `list` expose incremental hashing; `algorithms` lists the
closed set. `random` returns cryptographic bytes.

`store` is a binary-safe key/value layer over static SQLite. A bytearray is
stored byte-for-byte; another Tcl value uses its UTF-8 string representation.
`get` always returns a bytearray and raises `STORE notfound` for absence; `del` returns 0/1. `open`
without a path creates an in-memory store; `open path` creates or opens a durable
database. Both use a five-second busy timeout. `version` reports the SQLite version. See the
[contract](contract.md) for the cross-host guarantee.

## Program support

```tcl
set spec {
    --format {type string default text choices {text json} help "output format"}
    --jobs   {type int default 4 min 1 max 64 help "parallel workers"}
    --all    {type flag help "include hidden items"}
    path     {type string required 1 help "input path"}
}
set options [cli parse $argv $spec]
if {[dict get $options help]} { puts [cli usage $spec mytool]; exit }

log configure -level info -file mytool.log
log info "started" path [dict get $options path]
```

`cli parse` returns a dict and never prints or exits. Program options begin with
`--`; positionals follow declaration order. Attribute keys are `type`, `default`,
`min`, `max`, `choices`, `help`, and `required`; types are `flag`, `int`, and
`string`. `--help` is always returned as `help 1`. User mistakes raise `CLI
usage` with generated usage; invalid specifications raise `CLI badvalue`.
`cli duration` exposes the runtime duration parser.

`log` has levels `debug`, `info`, `warn`, `error`, and `off`. Configure a
`-channel` or append-only `-file`. Fields after the message are key/value pairs.
A write failure never interrupts the program; it increments `dropped`, reported
by `log configure`.

## Persistent workers

```tcl
# worker entry mode
worker on digest {path {alg sha256}} { hash file $alg $path }
worker serve

# director
set requests {{op digest path a.iso} {op digest path b.iso}}
set p [pool create -width 8 -maxtries 3 -- worker.exe]
pool submit $p $requests
set replies [pool wait $p -timeout 1m]
pool info $p
pool close $p

set results [pmap $requests -width 8 -- worker.exe]
```

`worker` implements a JSON-object-per-line protocol. `on` defines a compiled
handler whose argument list is its schema, `ops` describes registered handlers,
and `serve` reads stdin until EOF. Stdout is reserved for replies; diagnostics
belong in `log`/stderr.

`pool` maintains supervised `child -channels` workers with one in-flight item per
worker. Each pool accepts one submitted batch; create another pool for later
work. Results are ordered by submission ID; stderr is continuously drained and
capped for `info`. `create` accepts `-width`, `-maxtries`, and child launch
options `-arg0`, `-cpu`, `-dir`, `-env`, `-mem`, and `-timeout`. `wait` has its
own `-timeout`. Worker death requeues one item; repeated death returns a `POOL
poison` reply rather than looping.

`pmap` always closes its pool. It returns result values, or `-raw` replies. A
handler's structured error is re-raised unchanged; an unstructured handler error
becomes `PMAP failed`. See [parallel work](parallel.md).

## Serious calculation

```tcl
set h [macht load $rows -schema {naam s pad s status i bytes i}]
set waste [macht sum {$bytes} where {$status == 404 && [string match "/api/*" $pad]} -data $h]
set fast [macht sum {($a * $b + $c) % 97} where {$status < 500} -data $h -parallel auto]
```

`macht` compiles plain Tcl expr conditions into proven-equal bodies and
routes each run to whichever body the measurements earn — the Tcl arm, the
metered Lua cell, or an in-process shard pool for every core. Constructs
whose Tcl and Lua meanings diverge are refused by name; `macht stats` shows
every routing decision. See [the contract](contract.md) and
`machteld/command/macht`.

## Packaging and introspection

```tcl
version
manifest
docs status
docs get machteld/command/run
docs search {process lifetime timeout} -scope machteld -limit 10
dict get [manifest] run options
help
help contract

wrap app.tcl -o app.exe --console
wrap appdir -o app.exe --entry src/main.tcl --gui
```

`version` and `package require machteld` return `0.11.0`. `manifest` describes the
live public commands as structured data. Its `codes` are raised failures;
`replycodes` are fixed protocol failures carried as data. `docs` provides exact,
bounded, machine-readable access to the embedded Machteld, Tcl 9, and Tk 9
references; `help` is its human-facing shorthand.

`wrap` accepts only an opted-in Machteld entry. A directory defaults to
`main.tcl`; `--entry` selects another file inside it. It includes hidden assets
under an application subtree, validates the staged entry, publishes atomically,
and produces a console or GUI host with the same machine-control/data API,
static SQLite, Tcl/Tk libraries, version, and complete reference. Basekits are
not copied recursively, so a wrapped tool cannot perform another wrap. See
[packaging](packaging.md).

## Complete verb list

`canon`, `child`, `cli`, `detach`, `dirs`, `docs`, `hash`, `help`, `http`, `json`,
`links`, `log`, `macht`, `manifest`, `mtps`, `pmap`, `pool`, `pty`, `run`,
`scope`, `store`, `version`, `wait`, `watch`, `worker`, and `wrap`.
