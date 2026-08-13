---
id: machteld/command/child
type: command
title: child
summary: Own and supervise asynchronous process trees through opaque handles.
commands: child, child start, child wait, child kill, child info, child list, child close
---

# child

`child` separates launch, observation, termination, and release while preserving
the same Job Object supervision used by `run`.

## Synopsis

```tcl
child start ?launch options? ?--? command ?arg ...?
child wait token ?-timeout duration?
child kill token ?exitCode?
child info token
child list
child close token
```

## Arguments and options

Launch options are `-timeout`, `-mem`, `-cpu`, `-dir`, `-env`, `-arg0`,
`-stdin`, and `-channels`. They follow `run` except that `-timeout` is an
autonomous lifetime deadline and `-channels` exposes all three pipes. `-channels`
and `-stdin` are mutually exclusive. Observation timeout belongs only to
`child wait`.

## Results

`start` returns an opaque `child#...` token. `wait` returns the standard process
result dict. `info` returns at least `token`, `pid`, and `running`, plus `exit`
after reap and `stdin`, `stdout`, and `stderr` channel names in channel mode.
`list` returns owned tokens. `kill` and `close` return the empty value.

## Errors

Raised codes are `CHILD badvalue`, `CHILD launch`, `CHILD nohandle`,
`CHILD notfound`, `CHILD oserror`, and `CHILD usage`. Tcl may additionally
report wrong arity or value conversion. A wait deadline is a result state, not
an exception.

## Lifetime and timeouts

Every token owns a complete process tree. A start-time `-timeout` is enforced by
a monitor even if the script never waits. A wait-time `-timeout` bounds only
that call and leaves a running child alive. `close` is the release operation and
terminates the tree if needed. Interpreter shutdown also closes owned children.

## Examples

```tcl
set c [child start -timeout 2m -channels -- worker.exe]
set io [child info $c]
puts [dict get $io stdin] "request"
close [dict get $io stdin]
set result [child wait $c -timeout 10s]
child close $c
```

## Constraints

Channel mode transfers pipe-draining responsibility to the script. Undrained
stdout or stderr can fill and block a child. Close stdin when an EOF-driven
protocol has received its final request. A token is valid only in its creating
interpreter and until `close`.

## Subcommands

<a id="start"></a>
### start

#### Synopsis

`child start ?-timeout d? ?-mem size? ?-cpu d? ?-dir path? ?-env dict?
?-arg0 word? ?-stdin bytes? ?-channels? ?--? command ?arg ...?`

#### Arguments and options

The process options match `run`; defaults are inherited directory/environment,
no deadline or resource cap, captured output, and stdin connected to `NUL`.
`-channels` creates binary Tcl channels; otherwise output capture is bounded to
1 MiB per stream.

#### Results

Returns the new child token after successful born-in-job launch.

#### Errors

Reports invalid options/values, command resolution, launch, or channel setup in
the `CHILD` domain.

#### Lifetime and timeouts

The token owns the tree immediately. `-timeout` starts at launch and kills the
whole tree when elapsed.

#### Examples

`set c [child start -timeout 30s -- compiler.exe input.c]`

#### Constraints

`-channels` cannot be combined with `-stdin`; use the returned stdin channel.

#### See also

`machteld/command/run`, `machteld/command/scope`.

<a id="wait"></a>
### wait

#### Synopsis

`child wait token ?-timeout duration?`

#### Arguments and options

`-timeout` defaults to an unbounded observation wait and does not alter the
start-time lifetime deadline.

#### Results

Returns `status`, `exit`, `pid`, `out`, `err`, and `truncated`. If the
observation deadline expires first, `status` is `running` and the token remains
live.

#### Errors

Rejects stale tokens, malformed duration values, and wait failures.

#### Lifetime and timeouts

A completed child is reaped once; later waits return its retained result.

#### Examples

`if {[dict get [child wait $c -timeout 1s] status] eq "running"} { ... }`

#### Constraints

Waiting does not close the token.

#### See also

`machteld/command/wait`.

<a id="kill"></a>
### kill

#### Synopsis

`child kill token ?exitCode?`

#### Arguments and options

`exitCode` is an optional integer job-termination code and defaults to `1`.

#### Results

Returns empty after requesting termination of the complete job.

#### Errors

Rejects stale handles, invalid exit codes, or OS termination failure.

#### Lifetime and timeouts

The token remains owned; use `wait` to observe and `close` to release it.

#### Examples

`child kill $c`

#### Constraints

This kills descendants by Job Object identity, unlike PID-snapshot tree kill.

#### See also

`machteld/command/mtps#kill`.

<a id="info"></a>
### info

#### Synopsis

`child info token`

#### Arguments and options

Takes exactly one live child token and no options.

#### Results

Returns non-consuming state and channel names as described above.

#### Errors

A stale or foreign token reports `CHILD nohandle`.

#### Lifetime and timeouts

The query neither waits nor changes ownership.

#### Examples

`if {[dict get [child info $c] running]} { puts still-running }`

#### Constraints

`exit` is present only after reap; channel keys only after `-channels` start.

#### See also

`machteld/command/child#wait`.

<a id="list"></a>
### list

#### Synopsis

`child list`

#### Arguments and options

Takes no arguments or options.

#### Results

Returns all child tokens owned by this interpreter.

#### Errors

Only wrong arity is expected.

#### Lifetime and timeouts

Listing neither waits nor consumes handles.

#### Examples

`foreach c [child list] { puts [child info $c] }`

#### Constraints

The order is not a scheduling guarantee.

#### See also

`machteld/command/scope`.

<a id="close"></a>
### close

#### Synopsis

`child close token`

#### Arguments and options

Takes exactly one live child token.

#### Results

Returns empty.

#### Errors

A stale token reports `CHILD nohandle`. Once a live token is accepted, `close`
performs best-effort teardown and returns empty; it does not surface low-level
teardown failures as `CHILD oserror`.

#### Lifetime and timeouts

Closes exposed channels first, then attempts to kill a still-running tree and
release its native resources. The token becomes invalid even if low-level
teardown encounters an error.

#### Examples

`try { ... } finally { child close $c }`

#### Constraints

Do not use a token or its channel names after close.

#### See also

`machteld/command/scope`.

## See also

`machteld/command/run`, `machteld/command/wait`,
`machteld/command/scope`, `machteld/guide/execution-model`.
