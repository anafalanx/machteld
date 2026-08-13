---
id: machteld/command/log
type: command
title: log
summary: Write timestamped diagnostic records without letting sink failures interrupt the program.
commands: log, log configure, log debug, log info, log warn, log error
---

# log

## Synopsis

```tcl
log configure ?-level level? ?-channel channel|-file path?
log debug message ?key value ...?
log info message ?key value ...?
log warn message ?key value ...?
log error message ?key value ...?
```

## Arguments and options

Levels in increasing severity are `debug`, `info`, `warn`, and `error`; `off`
disables all records. Default threshold is `info`. The default sink resolves to
`stderr` at write time. `-channel` selects an existing open channel;
`-file` opens a path append-only with LF translation and line buffering. The
last sink option in one call wins.

## Results

`configure` without options returns `level`, active `channel`, `file`, and
`dropped`. Configuration with options returns empty. A log write returns `1`
when emitted and `0` when filtered or dropped. Records contain local timestamp,
uppercase level, message, and quoted `key=value` fields.

## Errors

Configuration raises `LOG badvalue`, `LOG oserror`, or `LOG usage`. A write
failure deliberately never raises; it increments `dropped`. An odd trailing
nonempty field is rendered as `key=?` rather than losing the diagnostic.

## Lifetime and timeouts

Configuration is interpreter-global. A file channel opened by `log` remains
open until another sink replaces it or interpreter shutdown. There are no
timeouts; writes and flushes are synchronous.

## Examples

```tcl
log configure -level debug -file C:/logs/tool.log
log info "scan complete" files 42 elapsed 850ms
if {[dict get [log configure] dropped]} { puts stderr "logs were lost" }
```

## Constraints

Logging is best-effort diagnostics, not a durable transaction journal. File or
channel blockage can block the caller. A GUI host may have no usable `stderr`,
which is why explicit `-file` is recommended there.

## Subcommands

<a id="configure"></a>
### configure

#### Synopsis

`log configure ?-level level? ?-channel channel|-file path?`

#### Arguments and options

All requested changes validate before any are committed. Setting a new owned
file/channel closes the prior file that `log` opened.

#### Results

No options returns the settings dict; options return empty.

#### Errors

An unknown channel reports `badvalue`; file-open failure is `oserror`. A known
but non-writable channel is accepted and its later writes increment `dropped`.

#### Lifetime and timeouts

Changes persist for the interpreter lifetime.

#### Examples

`log configure -level warn -channel stderr`

#### Constraints

The command does not reset the cumulative `dropped` counter.

#### See also

`machteld/command/log#info`.

<a id="debug"></a>
### debug

#### Synopsis

`log debug message ?key value ...?`

#### Arguments and options

Writes at the least severe/most verbose level.

#### Results

Returns emitted boolean.

#### Errors

Missing message is `LOG usage`; sink failures are counted, not raised.

#### Lifetime and timeouts

One synchronous record.

#### Examples

`log debug "request" id $id`

#### Constraints

Filtered at the default `info` threshold.

#### See also

`machteld/command/log#configure`.

<a id="info"></a>
### info

#### Synopsis

`log info message ?key value ...?`

#### Arguments and options

Writes a normal operational record.

#### Results

Returns emitted boolean.

#### Errors

Missing message is `usage`; sink failure is nonthrowing.

#### Lifetime and timeouts

One synchronous record.

#### Examples

`log info "started" pid [pid]`

#### Constraints

Enabled at the default threshold.

#### See also

`machteld/command/log#configure`.

<a id="warn"></a>
### warn

#### Synopsis

`log warn message ?key value ...?`

#### Arguments and options

Writes a warning record.

#### Results

Returns emitted boolean.

#### Errors

Missing message is `usage`; sink failure is nonthrowing.

#### Lifetime and timeouts

One synchronous record.

#### Examples

`log warn "queue near capacity" depth $n`

#### Constraints

No automatic retry or rotation.

#### See also

`machteld/command/log#configure`.

<a id="error"></a>
### error

#### Synopsis

`log error message ?key value ...?`

#### Arguments and options

Writes the highest-severity record; it does not raise a Tcl error.

#### Results

Returns emitted boolean.

#### Errors

Missing message is `usage`; sink failure remains nonthrowing.

#### Lifetime and timeouts

One synchronous record.

#### Examples

`log error "cannot process" path $path`

#### Constraints

Use Tcl `error` separately when control flow must fail.

#### See also

`machteld/command/log#configure`.

## See also

`machteld/command/cli`, `machteld/command/worker`.
