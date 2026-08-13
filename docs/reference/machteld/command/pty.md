---
id: machteld/command/pty
type: command
title: pty
summary: Drive interactive Windows console programs through a supervised ConPTY.
commands: pty, pty spawn, pty send, pty read, pty expect, pty strip, pty info, pty list, pty close
---

# pty

## Synopsis

```tcl
pty spawn ?launch options? ?--? command ?arg ...?
pty send token bytes
pty read token ?-timeout duration?
pty expect token ?-timeout duration? {pattern body ... ?timeout body?}
pty strip text
pty info token
pty list
pty close token
```

## Arguments and options

`spawn` accepts `-arg0`, `-cpu`, `-dir`, `-env`, and `-mem`. `read` polls by
default and accepts `-timeout`. `expect` defaults to `10s` and accepts
`-timeout`. The pseudoconsole size is currently fixed at 80 by 25 cells.

## Results

`spawn` returns a `pty#...` token. `read` returns up to 8192 raw VT/ANSI bytes,
or empty on timeout/EOF. `expect` returns the selected body's result. `strip`
returns text with common CSI, OSC, and escape sequences removed. `info` returns
`token`, `pid`, `running`, and pending-byte count `pending`; `list` returns
tokens. Mutating operations return empty.

## Errors

Raised codes are `PTY badvalue`, `PTY launch`, `PTY nohandle`, `PTY notfound`,
`PTY oserror`, `PTY timeout`, and `PTY usage`. A custom `timeout` body can choose
a different completion for `expect`.

## Lifetime and timeouts

Each PTY owns a supervised process tree in the host root job and a narrower
per-PTY job. `read -timeout` and `expect -timeout` bound observation only; there
is no PTY lifetime deadline. `close` terminates the tree and invalidates the
token. Interpreter shutdown closes remaining PTYs.

## Examples

```tcl
set p [pty spawn -- cmd.exe]
try {
    pty send $p "echo hello\r"
    pty expect $p -timeout 5s {
        {*hello*} { puts matched }
        timeout   { error "prompt did not answer" }
    }
} finally {
    pty close $p
}
```

## Constraints

ConPTY requires Windows 10 version 1809 or newer. It is a terminal byte stream,
not a line protocol; screen-control output can arrive split across reads. `strip`
is a pragmatic escape remover, not a full terminal emulator.

## Subcommands

<a id="spawn"></a>
### spawn

#### Synopsis

`pty spawn ?-arg0 word? ?-cpu d? ?-dir path? ?-env dict? ?-mem size? ?--?
command ?arg ...?`

#### Arguments and options

Launch options follow the corresponding `run` options; there is no `-timeout`.

#### Results

Returns a new PTY token after born-in-job launch.

#### Errors

Reports resolution, launch, option, and OS failures in the `PTY` domain.

#### Lifetime and timeouts

The process remains owned until `close` or interpreter shutdown.

#### Examples

`set p [pty spawn -dir C:/work -- powershell.exe -NoLogo]`

#### Constraints

The terminal dimensions cannot currently be configured or resized.

#### See also

`machteld/command/child#start`.

<a id="send"></a>
### send

#### Synopsis

`pty send token bytes`

#### Arguments and options

Writes the exact Tcl byte/string representation to the terminal input pipe.

#### Results

Returns empty after all bytes have been written.

#### Errors

Rejects stale tokens and reports pipe-write failures.

#### Lifetime and timeouts

The write is synchronous and has no timeout.

#### Examples

`pty send $p "dir\r"`

#### Constraints

Supply carriage return when the interactive program expects Enter.

#### See also

`machteld/command/pty#read`.

<a id="read"></a>
### read

#### Synopsis

`pty read token ?-timeout duration?`

#### Arguments and options

Without `-timeout`, performs an immediate poll. A zero duration is also a poll.

#### Results

Returns currently available raw terminal bytes, at most 8192 per call; empty
means no bytes arrived before the bound or the output pipe reached EOF.

#### Errors

Rejects bad durations/options and stale handles.

#### Lifetime and timeouts

Reading consumes bytes but never closes the PTY.

#### Examples

`append transcript [pty read $p -timeout 100ms]`

#### Constraints

Empty does not distinguish timeout from EOF; consult `pty info` when needed.

#### See also

`machteld/command/pty#expect`.

<a id="expect"></a>
### expect

#### Synopsis

`pty expect token ?-timeout duration? {glob body ... ?timeout body?}`

#### Arguments and options

Patterns use Tcl `string match` against an accumulating VT-stripped buffer.
The default timeout is 10 seconds. Bodies execute in the caller's scope.

#### Results

Returns the first matching body's result. The default timeout body raises
`PTY timeout`; an explicit `timeout` pattern supplies the alternate body.

#### Errors

Rejects odd pattern/body lists, unknown options, and stale handles. Body errors
propagate normally.

#### Lifetime and timeouts

It reads in bounded slices until a match or the deadline and leaves the PTY live.

#### Examples

`pty expect $p {{*Password:*} {pty send $p "$secret\r"}}`

#### Constraints

Matching sees stripped accumulated output, not a terminal screen model.

#### See also

`machteld/command/pty#strip`.

<a id="strip"></a>
### strip

#### Synopsis

`pty strip text`

#### Arguments and options

Takes text and no options; it does not require a PTY token.

#### Results

Returns text without common CSI, OSC, charset, keypad, cursor, and related
escape sequences.

#### Errors

Only Tcl wrong arity is expected.

#### Lifetime and timeouts

Pure transformation with no handle or timeout.

#### Examples

`puts [pty strip $raw]`

#### Constraints

Not a complete ECMA-48 parser or screen renderer.

#### See also

`machteld/command/pty#read`.

<a id="info"></a>
### info

#### Synopsis

`pty info token`

#### Arguments and options

Takes one token and no options.

#### Results

Returns `token`, root `pid`, boolean `running`, and non-consuming `pending`
bytes.

#### Errors

Rejects stale handles; job-state query can report `PTY oserror`.

#### Lifetime and timeouts

Does not read or alter the handle.

#### Examples

`dict get [pty info $p] pending`

#### Constraints

`pending` is a pipe-byte count, not terminal character or line count.

#### See also

`machteld/command/pty#read`.

<a id="list"></a>
### list

#### Synopsis

`pty list`

#### Arguments and options

Takes no arguments.

#### Results

Returns live PTY tokens owned by the interpreter.

#### Errors

Only wrong arity is expected.

#### Lifetime and timeouts

Does not change ownership.

#### Examples

`foreach p [pty list] { puts [pty info $p] }`

#### Constraints

Ordering is not a scheduling contract.

#### See also

`machteld/command/pty#close`.

<a id="close"></a>
### close

#### Synopsis

`pty close token`

#### Arguments and options

Takes one live token.

#### Results

Returns empty.

#### Errors

Rejects stale tokens and reports teardown failure as `PTY oserror`.

#### Lifetime and timeouts

Terminates the complete PTY job, drains final output during ConPTY teardown,
and invalidates the token.

#### Examples

`try { ... } finally { pty close $p }`

#### Constraints

Do not use the token after close.

#### See also

`machteld/command/child#close`.

## See also

`machteld/command/run`, `machteld/command/child`,
`machteld/guide/execution-model`.
