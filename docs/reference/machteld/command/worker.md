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
worker serve
```

## Arguments and options

Operation names begin with a letter or underscore and then use letters, digits,
underscore, dot, or hyphen. `arglist` is a Tcl procedure argument list and is
the request schema; defaults make fields optional. The handler is compiled as a
real proc in the caller's namespace. There are no options.

## Results

`on` returns empty. `ops` returns a dict from operation name to its argument
schema including defaults. `serve` returns empty at stdin EOF. On the wire,
success is `{id N ok 1 result value}` and failure is
`{id N ok 0 code errorCode msg message}` encoded as one JSON object per line.

## Errors

Direct command failures are `WORKER badvalue` and `WORKER usage`. Protocol
failures are reply data with `WORKER failed`, `WORKER notfound`, `WORKER parse`,
or `WORKER usage`. A handler's structured error code is preserved in its reply.

## Lifetime and timeouts

Definitions persist for the interpreter lifetime; redefining an operation
replaces its proc mapping. `serve` blocks reading requests until EOF and has no
timeout. A pool provides the supervising lifetime and retry policy.

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

`worker serve`

#### Arguments and options

Configures stdin/stdout as UTF-8 LF streams and reads one nonempty JSON line per
request until EOF.

#### Results

For each nonempty request, attempts one encoded reply line and then continues;
returns on EOF.

#### Errors

Bad input, unknown operation, missing field, and handler error become failure
replies rather than server-terminating exceptions. A reply encoding/write
failure is contained and can leave that request unanswered. Wrong command arity
is raised before serving.

#### Lifetime and timeouts

Intentionally blocking and unbounded; the director closes stdin to stop it.

#### Examples

`worker serve`

#### Constraints

Any handler output to stdout corrupts framing and can cause pool retry/poison.

#### See also

`machteld/command/pool`, `machteld/guide/parallel`.

## See also

`machteld/command/pool`, `machteld/command/pmap`,
`machteld/guide/parallel`.
