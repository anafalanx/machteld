---
id: machteld/command/watch
type: command
title: watch
summary: Observe bounded, disclosed Windows directory-change streams through opaque handles.
commands: watch, watch start, watch read, watch info, watch list, watch close
---

# watch

## Synopsis

```tcl
watch start directory ?-recursive?
watch read token ?-timeout duration? ?-raw?
watch info token
watch list
watch close token
```

## Arguments and options

`start -recursive` includes descendants; otherwise only the named directory is
watched. `read -timeout` waits for the first available state and defaults to an
immediate poll. `read -raw` preserves the OS event sequence; default mode
coalesces one read batch deterministically.

## Results

`start` returns `watch#...`. `read` returns event dicts containing `path` and
`action`, optional rename `from`, or an `overflow` row with `count`. `info`
returns `token`, `directory`, `recursive`, `armed`, `pending`, `dropped`,
`failed`, and `win32`. `list` returns tokens. `close` returns empty.

## Errors

Raised codes are `WATCH badvalue`, `WATCH nohandle`, `WATCH notfound`,
`WATCH oserror`, and `WATCH usage`. A watch that fails asynchronously reports
`WATCH oserror` on the next read; `info` exposes its state without consuming it.

## Lifetime and timeouts

`start` does not return until the first OS read is armed, closing the race in
which an immediate change could otherwise be missed. A read timeout bounds only
the call. The watch remains owned until `close` or interpreter shutdown.

## Examples

```tcl
set w [watch start C:/src -recursive]
try {
    foreach event [watch read $w -timeout 2s] {
        puts "[dict get $event action] [dict get $event path]"
    }
} finally {
    watch close $w
}
```

## Constraints

The queue is bounded. OS-buffer or queue overflow is disclosed, after which the
consumer must rescan if it needs a complete view. Paths are relative to the
watched directory. Filesystem changes can be reordered or coalesced by Windows;
the stream is notification, not a transaction log.

## Subcommands

<a id="start"></a>
### start

#### Synopsis

`watch start directory ?-recursive?`

#### Arguments and options

The directory must be openable for change notification. `-recursive` includes
the subtree and defaults off.

#### Results

Returns a token only after successful arming.

#### Errors

Missing/unopenable directories report `notfound`; allocation, thread, or arming
failures report `oserror`.

#### Lifetime and timeouts

Starts a background watcher owned by the token; arming itself is bounded by an
internal five-second safety wait.

#### Examples

`set w [watch start C:/work -recursive]`

#### Constraints

The directory path is retained for diagnostics; moving or deleting it can fail
the active watch.

#### See also

`machteld/command/dirs`.

<a id="read"></a>
### read

#### Synopsis

`watch read token ?-timeout duration? ?-raw?`

#### Arguments and options

`-timeout` defaults to zero/poll. `-raw` defaults false. Duplicate options are
rejected.

#### Results

Consumes and returns the current batch. Default precedence is removed, added,
renamed, then modified; paired renames use action `renamed` and `from`.

#### Errors

Bad options/durations, stale handles, wait failure, and asynchronous watch
failure use the documented `WATCH` codes.

#### Lifetime and timeouts

Timeout returns an empty list and leaves the handle live.

#### Examples

`set batch [watch read $w -timeout 500ms]`

#### Constraints

An overflow row means the batch is incomplete.

#### See also

`machteld/command/wait`.

<a id="info"></a>
### info

#### Synopsis

`watch info token`

#### Arguments and options

Takes one token and no options.

#### Results

Returns the fixed state dict without consuming events.

#### Errors

A stale token reports `WATCH nohandle`.

#### Lifetime and timeouts

Immediate observation only.

#### Examples

`if {[dict get [watch info $w] dropped]} { set rescan 1 }`

#### Constraints

State may change immediately after return.

#### See also

`machteld/command/watch#read`.

<a id="list"></a>
### list

#### Synopsis

`watch list`

#### Arguments and options

No arguments.

#### Results

Returns owned watch tokens.

#### Errors

Only wrong arity is expected.

#### Lifetime and timeouts

Does not change handles.

#### Examples

`foreach w [watch list] { puts [watch info $w] }`

#### Constraints

Ordering is unspecified.

#### See also

`machteld/command/watch#close`.

<a id="close"></a>
### close

#### Synopsis

`watch close token`

#### Arguments and options

Takes one live watch token.

#### Results

Returns empty.

#### Errors

Teardown failure reports `WATCH oserror`; stale tokens report `nohandle`.

#### Lifetime and timeouts

Cancels pending I/O, stops the watcher, drops queued events, and invalidates the
token.

#### Examples

`try { ... } finally { watch close $w }`

#### Constraints

Unread events do not survive close.

#### See also

`machteld/command/watch#start`.

## See also

`machteld/command/wait`, `machteld/command/dirs`.
