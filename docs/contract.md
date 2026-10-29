---
type: contract
title: Runtime contract
description: Entry, value, option, time, error, handle, and metadata conventions.
tags: [machteld, contract, api, errors]
---

# Runtime contract

This file states the cross-command rules. Command-specific vocabulary is in the
[palette](palette.md); the live authority is `manifest`.

Repository documentation describes the unsigned runtime candidate `0.22`, whose
release gate is still in progress. The previously signed `dist/0.21` release
retains its original behavior. Consult the selected executable's own embedded
reference and artifact identity rather than applying candidate documentation
retroactively to that release.

## Platform

Machteld targets x64 Windows 11 25H2 (build 26200) and Windows
Server 2025 (build 26100) or newer. Windows 10 and Server 2022/2019 are below
the contracted floor, and ARM64 is not a target. These are the platform policy,
not a claim of acceptance on every listed OS. Current local validation is on
x64 Windows 11 Pro build 26200; Server 2025 acceptance remains separate work.
The binary may start on older builds — ConPTY has existed since Windows 10
1809 — but that API minimum does not widen the supported platform policy.

## Entry and package

A direct program is a readable UTF-8 file whose first executable command is one
of these literal forms. `.tcl` is conventional, not required:

```tcl
package require machteld
package require machteld 0.22
package require -exact machteld 0.22
```

The words must be simple literals; substitutions are not an opt-in. A UTF-8 BOM
is accepted. The host parses this boundary before evaluating the file. A missing
file fails with `{MACHTELD ENTRY notfound}` and a file without the opt-in fails
with `{MACHTELD ENTRY optin}`. A missing or damaged embedded prelude fails with
`{MACHTELD ENTRY payload}`. These startup failures exit before the program can
be evaluated. Programs from stdin are not accepted.

Once loaded, `package require machteld` returns `0.22`. Palette commands are in
`::machteld`, which is on the global namespace path. A nested namespace may add
`namespace path ::machteld` or use qualified names.

## Values

- Commands return Tcl values; they do not print as a side effect unless output
  is their stated purpose (`log`, `worker serve`, or an inherited child).
- Records are dicts, collections are lists, and flags are `0` or `1`. Commands
  with a binary result contract return bytearrays. `pty` is a terminal-string
  interface, not a binary channel; see its reference before processing bytes.
  JSON container identity is preserved by `json`, subject to Tcl shimmering;
  use typed JSON when scalar distinctions must survive composition.
- Where a command consumes bytes (`hash`, `store put`, `http post`, `run` and
  `child start -stdin`), a bytearray is used byte-for-byte and any other value
  as UTF-8, the bytes `encoding convertto utf-8` produces. The rule is
  type-based: a string that merely looks binary is still text.
- Filesystem results use normalized Tcl paths. A returned path is data, not a
  shell command line.
- Process capture returns a dict containing `status`, `exit`, `pid`, `out`,
  `err`, and `truncated`. `status` distinguishes normal exit, timeout, and other
  termination outcomes; consult the value rather than parsing prose. Buffered
  capture retains the first 1 MiB of each stream. `truncated` lists `out`
  and/or `err` when that limit was exceeded. Use `run -onout/-onerr`, `child
  start -channels`, or inherited output when a stream can be larger. Callback
  lines have a separate 16 MiB incoming-byte bound (LF excluded, CR included);
  exceeding it raises `RUN limit` and terminates the tree, never silently
  converting lines into chunks. `exit` is
  the root process's exit code; `status` describes the supervised tree. A root
  can therefore exit `0` before its surviving descendant reaches a lifetime
  deadline, producing `status timeout` with `exit 0`.

## Options, commands, and durations

Palette options use a single leading dash. Program arguments after a launcher
are separated with `--` whenever an option-shaped argument would be ambiguous:

```tcl
run -timeout 30s -dir C:/work -- tool.exe -its-own-option
```

Durations are exactly one or more decimal digits followed by `ms`, `s`, `m`, or
`h`: no sign, decimal point, whitespace, or bare number. Thus `500ms` and `2h`
are valid while `0.5s`, `+5s`, and `100` are not. HTTP additionally refuses a
zero timeout because WinHTTP defines zero as infinite, which would violate an
explicit timeout. Finite process/observation timeouts and `cli duration` are
bounded to `4294967294ms`; HTTP accepts `1` through `2147483647` milliseconds.
CPU-time limits use a separate 100-nanosecond Job Object counter, not the
finite-wait range. For `http`, timeout is applied by WinHTTP to each network
phase, not as one wall-clock deadline over the complete operation. The
[execution model](execution-model.md) distinguishes observation from lifetime
deadlines and explains event-loop behavior.

Sizes are a non-negative decimal integer followed by an optional binary suffix
`B`, `K`, `KB`, `M`, `MB`, `G`, or `GB`, case-insensitively. No decimal point,
sign, or whitespace is accepted. `8M` and `8388608` therefore name the same
size. The grammar is shared by byte/body and memory limits. A process memory cap
may be zero to mean "no cap"; HTTP `-maxbody` must be positive.

Unknown options, missing values, and wrong public arity are errors. Subcommand
options are not silently accepted by another branch.

## Errors

A domain failure defined by Machteld has a three-part Tcl `-errorcode`:

```text
MACHTELD DOMAIN code
```

The domain identifies the command family, not the internal helper. The lowercase
code is stable enough to trap; the message is a diagnostic for a person and may
contain operating-system or SQLite text.

Tcl itself can reject a call before a Machteld domain failure is appropriate.
Wrong arity, a failed ensemble/subcommand lookup, or Tcl value conversion may
therefore retain core codes such as `TCL WRONGARGS`, `TCL LOOKUP`, or `TCL VALUE`.
Manifest `codes` is the closed set of `{MACHTELD DOMAIN code}` failures for that
command, not a claim to replace Tcl's own language-level errors.

```tcl
store open
try {
    store get missing
} trap {MACHTELD STORE notfound} {message options} {
    # expected absence
} finally {
    store close
}
```

The current domains are `ENTRY`, `RUN`, `CHILD`, `WAIT`, `DETACH`, `PTY`,
`WATCH`, `MTPS`, `DIRS`, `HTTP`, `HASH`, `JSON`, `STORE`, `CLI`, `LOG`,
`WORKER`, `POOL`, `PMAP`, `DOCS`, `HELP`, and `WRAP`. Common codes include `usage`,
`badvalue`, `notfound`, `nohandle`, `timeout`, `launch`, and `oserror`; each
manifest entry lists its closed set of Machteld-domain codes.

A failure raised by a worker handler crosses the JSON-lines boundary as data.
`pmap` re-raises a handler's meaningful error code unchanged. Protocol failures
use `WORKER parse/notfound/usage/failed/limit`; an item whose permitted attempts
end without a valid reply is returned with code `{MACHTELD POOL poison}`.
This does not prove the item caused the worker's death or had no side effect;
the default is one attempt, with no automatic replay. Manifest
`replycodes` records these data-level protocol codes separately from raised
`codes`; handler-defined reply codes are necessarily open-ended.

## Handles and lifetime

`child`, `pty`, `watch`, `hash start`, and `pool create` return opaque tokens.
Only their owning command accepts them; stale or foreign tokens fail instead of
being guessed. `info` observes a handle without consuming it. `close` is the
explicit release operation except for incremental hashes, where `hash final`
returns the digest and consumes the token.

The host owns, but does not belong to, its root kill-on-close Job Object. All
supervised child and PTY trees are born into that root job and a per-command job.
`scope` closes children born inside its body on every exit path. `detach` joins
neither job: success means the new process has been verified outside every
Windows job. Within Machteld's process palette, it is the explicit route outside
that lifetime. Ordinary Tcl `exec` and pipe channels remain available, but are
not covered by Machteld's supervision contract. If an enclosing Windows job forbids breakaway, `detach` fails
with `{MACHTELD DETACH launch}` rather than return a still-attached PID.

Supervision is lifetime ownership, not an authority sandbox. Children run with
the launching user's access token and permissions. `-dir` sets a working
directory, not a filesystem boundary; `-env` overlays the inherited environment,
not a clean or credential-isolated environment. Trusted Tcl and native
extensions likewise run with the host's authority.

`-mem` is a per-process committed-memory limit implemented by
`JOB_OBJECT_LIMIT_PROCESS_MEMORY`, not a working-set/RSS limit or a combined
tree budget. An allocation beyond it may fail; it is not a promise of a distinct
Machteld "out of memory" status. `-cpu` uses
`JOB_OBJECT_LIMIT_PROCESS_TIME`: cumulative user-mode CPU time per process, not
wall time, a CPU percentage, or a combined tree budget. Descendants are subject
to the same per-process limits. A pool multiplies the possible resource use by
its workers and any descendants; neither cap bounds the director's Tcl heap.
Only the explicit process-tree lifetime timeout is reported as `status timeout`.
Cancellation and resource-limit termination do not roll back side effects.

## Store

`store` is a narrow key/value API over statically linked SQLite, not an SQL
escape hatch. Keys are text. Values are binary-safe: `put` stores the exact Tcl
bytes of a bytearray; other Tcl values are stored using their UTF-8 string
representation. `get` always returns a bytearray. A missing key raises
`{MACHTELD STORE notfound}`. `del` returns `1` when it removed a key and `0` when
the key did not exist. Operations before `open` raise `STORE notopen`.

`store open` creates an in-memory database. `store open path` creates the
key/value table when needed in a durable database. Both configure a five-second
SQLite busy timeout, allowing independent Machteld processes to wait through
ordinary writer contention. SQLite failures use `STORE sqlite`.
Every full, console-wrapped, and GUI-wrapped host built from this tree includes
this same static implementation. It exposes no SQL or multi-operation
transaction API; individual calls do not make an application workflow atomic.

## Manifest

`manifest` returns a dict keyed by public command. An entry can contain:

- `kind`: `c` or `tcl`;
- `domain` and `codes` for structured failures;
- `replycodes` for fixed codes carried as protocol data rather than raised;
- `doc`: the stable `machteld/command/<verb>` reference identifier;
- `options` for the command as a whole;
- `subcommands`, each with its own `options`;
- `returns` for fixed-shape result dicts;
- `defaults` and `limits` where explicitly authored, not a universal model of
  each command's resource costs.

Native facts are authored in the build metadata and checked against registered C
commands. Tcl commands call an explicit metadata registry. Duplicate facts fail
the build/runtime merge unless they are the intentional Tcl extension of `pty`.
Implementation-body scanning is not part of the contract.

## The bounded-delivery covenant

Doctrine for every future network organ and for every incubated network
package at its admission gate (recorded from real WebSocket/CDP field work;
the originating handoff lives at the repository root):

This is an admission policy, not a claim that every existing command has an
evented interface or a shared aggregate memory budget. In particular, `http`
is synchronous and `run` line callbacks execute on the calling Tcl thread.

- OS, native, and channel callbacks ENQUEUE; they never evaluate application
  Tcl. Public timer and event scripts carry only opaque handles or delivery
  ids.
- Payload queues are bounded in count and bytes, per handle and in aggregate
  per interpreter; a terminal event has reserved capacity, so saturation can
  always be disclosed generically.
- Cancellation and close purge payloads and decrement every counter exactly;
  stale notifications become no-ops.
- Callback and notifier failure is caught, cleanup runs, and only fixed
  error tokens escape. Nothing reaches `bgerror` or Tk's modal error path.
- Wire payload, URL query, headers, negotiated protocol names, close
  reasons, and peer-controlled text never appear in errors, traces, info
  results, logs, manifests, or scheduled scripts; payload-bearing values are
  exposed only through an explicit receive result.
- Prefer pull: a readiness callback receives only the opaque handle, and the
  application explicitly asks for data.

## Compatibility

The executable, wrapped console host, and wrapped GUI host all provide Machteld
0.22 and the same machine-control, data, process, and Tcl composition commands,
including `package require Tk` and static `store`. The distribution includes the
complete exact-version reference corpus. Wrapped tools omit it by default;
`wrap --with-docs` includes the verified complete corpus. Runtime libraries,
license notices, and application assets are retained either way. Without the
corpus, `docs schema` remains available, corpus queries report `DOCS unsupported`,
and `help` queries report `HELP unsupported`; bare `help` explains the omission.
The reserved `--machteld-docs` host route remains available with structured
unavailable replies for corpus queries. Nested wrapping is intentionally
nonrecursive: `wrap` reports `WRAP unsupported` because tools carry no nested
basekits, even when they include the reference.

The API remains pre-1.0: 0.x releases may remove a mistaken surface. Within a
release, `version`, `manifest`, package version, docs, and both wrapper hosts must
agree.
