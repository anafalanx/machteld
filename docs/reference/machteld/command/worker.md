---
id: machteld/command/worker
type: command
title: worker
summary: Define named operations and serve a JSON-object-per-line worker protocol.
commands: worker, worker on, worker ops, worker serve
---

# worker

## Synopsis

```tcl
worker on operation arglist body
worker ops
worker serve ?-maxframe bytes?
```

## Arguments and options

Operation names begin with a letter or underscore and then use letters, digits,
underscore, dot, or hyphen. `arglist` is a Tcl procedure argument list and is
the request schema; defaults make fields optional. The handler is compiled as a
real proc in the caller's namespace. `serve -maxframe` bounds each request and
reply to 16777216 (16 MiB) UTF-8 bytes by default, excluding LF but including
any trailing CR. It accepts integers from 1 through 2147483647; size suffixes
and an unlimited setting are not supported.

## Results

`on` returns empty. `ops` returns a dict from operation name to its argument
schema including defaults. `serve` returns empty at stdin EOF. On the wire,
success is `{id N ok 1 result value}` and failure is
`{id N ok 0 code errorCode msg message}` encoded as one JSON object per line.

## Errors

Direct command failures are `WORKER badvalue`, `WORKER limit`, and `WORKER usage`.
Protocol failures are reply data with `WORKER failed`, `WORKER limit`, `WORKER notfound`, `WORKER parse`,
or `WORKER usage`. A handler's structured error code is preserved in its reply.
An oversized request terminates `serve` with `WORKER limit` before JSON decode
or handler dispatch, even without LF or EOF. An oversized encoded reply becomes
a small `WORKER limit` failure reply; if even that cannot fit (for example an
extremely small limit or enormous echoed ID), `serve` raises `WORKER limit`.
Stdout I/O failure also terminates serving instead of silently continuing.

## Lifetime and timeouts

Definitions persist for the interpreter lifetime; redefining an operation
replaces its proc mapping. `serve` blocks reading requests until EOF and has no
timeout. A pool provides the supervising lifetime and retry policy. The
default pool policy is one attempt: a lost reply may follow a completed side
effect and is not automatically replayed.

## Examples

```tcl
worker on digest {path {algorithm sha256}} {
    hash file $algorithm $path
}
worker serve
```

## Constraints

Stdout is exclusively the JSON-lines protocol. Handler diagnostics must use
`log`, stderr, or a file. Requests must be JSON objects with `op` and named
argument fields. `id` is echoed when present and defaults to `-1` for a direct
client; pools always assign it. Machteld sends data, never scripts or closures.

## Subcommands

<a id="on"></a>
### on

#### Synopsis

`worker on operation arglist body`

#### Arguments and options

Defines a Tcl proc in the calling namespace. Named request fields bind to its
arguments; Tcl defaults are honored and an `args` tail may be absent.

#### Results

Returns empty.

#### Errors

Invalid operation name or procedure argument list reports `WORKER badvalue` or
a Tcl proc-definition error; wrong arity is `WORKER usage`.

#### Lifetime and timeouts

The compiled handler persists until replaced or interpreter exit.

#### Examples

`worker on size {path} {file size $path}`

#### Constraints

A nested namespace must arrange its ordinary command resolution, including
`namespace path ::machteld` when using bare palette verbs.

#### See also

`machteld/command/worker#ops`.

<a id="ops"></a>
### ops

#### Synopsis

`worker ops`

#### Arguments and options

No arguments.

#### Results

Returns the self-describing operation schemas.

#### Errors

Wrong arity is `WORKER usage`.

#### Lifetime and timeouts

Immediate, nonmutating query.

#### Examples

`puts [worker ops]`

#### Constraints

The schemas describe fields/defaults, not handler result types.

#### See also

`machteld/command/manifest`.

<a id="serve"></a>
### serve

#### Synopsis

`worker serve ?-maxframe bytes?`

#### Arguments and options

Reads bounded binary chunks from stdin, then strictly decodes each complete
nonempty UTF-8 JSON line. A split UTF-8 character is retained until its frame
is complete. A complete final JSON object without LF is accepted at EOF.
Stdout carries UTF-8 LF-delimited replies. `-maxframe` applies independently
of the director/pool's configured frame limit.

#### Results

For each nonempty request, attempts one encoded reply line and then continues;
returns on EOF.

#### Errors

Bad input, unknown operation, missing field, and handler error become failure
replies rather than server-terminating exceptions. A reply that cannot be
encoded as plain JSON, such as a result carrying a typed json value, is answered
with a `WORKER failed` reply. Invalid UTF-8 becomes a `WORKER parse` reply.
Oversized input terminates serving; oversized output is handled as described
above. A failed write or an impossibly small reply limit can leave a request
unanswered. Wrong command arity or invalid bounds are raised before serving.

#### Lifetime and timeouts

Intentionally synchronous; the director closes stdin to stop it after already
accepted requests have been handled. EOF is not cancellation of an executing
handler. Frame memory is bounded, but handler running time and handler-created
data are not. Use the supervising child's lifetime deadline and per-process
memory cap where needed, or close the owned child to terminate it. None of
these actions rolls back a handler's side effects.

#### Examples

`worker serve`

#### Constraints

Any handler output to stdout corrupts framing and can cause a pool poison
reply (and retries only when explicitly enabled). The frame limit is not a
whole-process memory bound: JSON serialization and decoded Tcl values have
overhead, and handler results already exist before encoding.

#### See also

`machteld/command/pool`, `machteld/guide/parallel`.

## See also

`machteld/command/pool`, `machteld/command/pmap`,
`machteld/guide/parallel`.
