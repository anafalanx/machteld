---
type: contract
title: Runtime contract
description: Entry, value, option, time, error, handle, and metadata conventions.
tags: [machteld, contract, api, errors]
---

# Runtime contract

This file states the cross-command rules. Command-specific vocabulary is in the
[palette](palette.md); the live authority is `manifest`.

## Platform

The 0.10.0 artifact targets x64 Windows 10 version 1809 or newer, including
Windows 11 and corresponding Windows Server releases. ConPTY determines the OS
floor. Other architectures and older Windows versions are not release targets.

## Entry and package

A direct program is a readable UTF-8 file whose first executable command is one
of these literal forms. `.tcl` is conventional, not required:

```tcl
package require machteld
package require machteld 0.10.0
package require -exact machteld 0.10.0
```

The words must be simple literals; substitutions are not an opt-in. A UTF-8 BOM
is accepted. The host parses this boundary before evaluating the file. A missing
file fails with `{MACHTELD ENTRY notfound}` and a file without the opt-in fails
with `{MACHTELD ENTRY optin}`. A missing or damaged embedded prelude fails with
`{MACHTELD ENTRY payload}`. These startup failures exit before the program can
be evaluated. Programs from stdin are not accepted.

Once loaded, `package require machteld` returns `0.10.0`. Palette commands are in
`::machteld`, which is on the global namespace path. A nested namespace may add
`namespace path ::machteld` or use qualified names.

## Values

- Commands return Tcl values; they do not print as a side effect unless output
  is their stated purpose (`log`, `worker serve`, or an inherited child).
- Records are dicts, collections are lists, flags are `0` or `1`, and byte
  payloads are bytearrays. JSON container identity is preserved by `json`.
- Filesystem results use normalized Tcl paths. A returned path is data, not a
  shell command line.
- Process capture returns a dict containing `status`, `exit`, `pid`, `out`,
  `err`, and `truncated`. `status` distinguishes normal exit, timeout, and other
  termination outcomes; consult the value rather than parsing prose. Buffered
  capture retains the first 1 MiB of each stream. `truncated` lists `out`
  and/or `err` when that limit was exceeded. Use `run -onout/-onerr`, `child
  start -channels`, or inherited output when a stream can be larger. `exit` is
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
explicit timeout. For `http`, this timeout is applied by WinHTTP to each network
phase, not as one wall-clock deadline over the complete operation.

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
try {
    store get missing
} trap {MACHTELD STORE notfound} {message options} {
    # expected absence
}
```

The current domains are `ENTRY`, `RUN`, `CHILD`, `WAIT`, `DETACH`, `PTY`,
`WATCH`, `MTPS`, `DIRS`, `HTTP`, `HASH`, `JSON`, `STORE`, `CLI`, `LOG`,
`WORKER`, `POOL`, `PMAP`, `DOCS`, `HELP`, and `WRAP`. Common codes include `usage`,
`badvalue`, `notfound`, `nohandle`, `timeout`, `launch`, and `oserror`; each
manifest entry lists its closed set of Machteld-domain codes.

A failure raised by a worker handler crosses the JSON-lines boundary as data.
`pmap` re-raises a handler's meaningful error code unchanged. Protocol failures
use `WORKER parse/notfound/usage/failed`; an item that repeatedly kills workers
is returned by the pool with code `{MACHTELD POOL poison}`. Manifest
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
Windows job. It is the only API that intentionally creates a process tree
outside that lifetime. If an enclosing Windows job forbids breakaway, it fails
with `{MACHTELD DETACH launch}` rather than return a still-attached PID.

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
ordinary writer contention. Engine failures use `STORE sqlite`.
Every full, console-wrapped, and GUI-wrapped 0.10.0 host includes this same static
implementation.

## Manifest

`manifest` returns a dict keyed by public command. An entry can contain:

- `kind`: `c` or `tcl`;
- `domain` and `codes` for structured failures;
- `replycodes` for fixed codes carried as protocol data rather than raised;
- `doc`: the stable `machteld/command/<verb>` reference identifier;
- `options` for the command as a whole;
- `subcommands`, each with its own `options`;
- `returns` for fixed-shape result dicts.

Native facts are authored in the build metadata and checked against registered C
commands. Tcl commands call an explicit metadata registry. Duplicate facts fail
the build/runtime merge unless they are the intentional Tcl extension of `pty`.
Implementation-body scanning is not part of the contract.

## Compatibility

The executable, wrapped console host, and wrapped GUI host all provide Machteld
0.10.0 and the same machine-control, data, process, and Tcl composition commands,
including `package require Tk`, static `store`, and the complete exact-version
reference corpus. Nested wrapping alone is intentionally nonrecursive: `wrap`
reports `WRAP unsupported` because tools carry no nested basekits. Deliberately
bare internal hosts can report `DOCS unsupported`/`HELP unsupported` because
they carry no reference payload.

The API remains pre-1.0: 0.x releases may remove a mistaken surface. Within a
release, `version`, `manifest`, package version, docs, and both wrapper hosts must
agree.
