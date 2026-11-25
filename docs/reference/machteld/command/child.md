---
id: machteld/command/child
type: command
title: child
summary: Own and supervise asynchronous process trees through opaque handles.
commands: child, child start, child present, child wait, child shutdown, child kill, child info, child list, child close
---

# child

`child` separates launch, observation, termination, and release while preserving
the same Job Object supervision used by `run`.

## Synopsis

```tcl
child start ?launch options? ?--? command ?arg ...?
child present token ?-class name?
child wait token ?-timeout duration?
child shutdown token
child kill token ?exitCode?
child info token
child list
child close token
```

## Arguments and options

Launch options are `-timeout`, `-mem`, `-cpu`, `-dir`, `-env`, `-arg0`,
`-stdin`, `-channels`, `-onexit commandPrefix`, `-console default|none`,
and `-window default|visible|hidden|normal`. The start-time `-timeout` is an
autonomous lifetime deadline. `-channels` exposes all three pipes. `-channels`
and `-stdin` are mutually exclusive. Observation timeout belongs only to
`child wait`.

## Results

`start` returns an opaque `child#...` token. `wait` returns the standard process
result dict. `info` returns at least `token`, `pid`, and `running`, plus `exit`
after reap and `stdin`, `stdout`, and `stderr` channel names in channel mode.
`list` returns owned tokens. `kill` and `close` return the empty value.
`present` returns a snapshot of a window owned by the child or one of its
supervised descendants.

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
set c [child start -timeout 2m -- compiler.exe input.c]
try {
    set result [child wait $c]
} finally {
    child close $c
}
```

For a complete evented channel-mode example, see
`examples/project-inspector/model.tcl` in the repository. Do not copy a pattern
that sends a request and then blocks in `child wait` without draining its pipes.

## Constraints

Channel mode transfers pipe-draining responsibility to the script. Undrained
stdout or stderr can fill and block a child. Close stdin when an EOF-driven
protocol has received its final request. The exposed channels start in binary,
blocking mode; explicitly set `-blocking 0` before evented I/O and drain both
streams in bounded callbacks. `child wait` blocks the calling thread and does
not pump channel events, so do not wait indefinitely for a child whose output
still needs those callbacks. A token is valid only in its creating interpreter
and until `close`. Channel names can be reused after a channel is closed; do
not cache them as permanent identities or use an old name after closing it.

As for `run`, the memory cap is per-process committed memory, the CPU cap is
per-process user-mode CPU time, and neither is a total-tree budget or a
permissions sandbox. Observation timeout does not cancel work. Kill, lifetime
timeout, and close do not roll back side effects.

## Subcommands

<a id="start"></a>
### start

#### Synopsis

`child start ?-timeout d? ?-mem size? ?-cpu d? ?-dir path? ?-env dict?
?-arg0 word? ?-stdin bytes? ?-channels? ?-console default|none?
?-window default|visible|hidden|normal? ?-onexit commandPrefix? ?--? command ?arg ...?`

#### Arguments and options

The process options match `run`; defaults are inherited directory/environment,
no deadline or resource cap, captured output, and stdin connected to `NUL`.
`-channels` creates binary Tcl channels; otherwise output capture is bounded to
1 MiB per stream.

`-console default` (the default) uses ordinary Windows console attachment.
`-console none` starts the target without attaching or allocating a console.
Windows calls this creation mode `DETACHED_PROCESS`. Use it for a console
helper started by a GUI. Input, captured output, channel
mode, and ownership of the process tree work as usual. A program can still
create its own windows or console and choose how it launches descendants.

`-window visible` requests a normal initial window and enables `child present`
for this token. `normal` is an alias for `visible`. Use `-window hidden` for
a helper that should start with its first window hidden. The default,
`-window default`, leaves the initial show state to the application. All
settings work with either console setting. Windows passes the request to the
launched process. The application controls later window changes and the
initial state of processes it launches itself.

With `-onexit`, the owning interpreter's event loop invokes
`{*}$commandPrefix $token $result` once when the whole job exits and native
capture has drained. The prefix must be a nonempty Tcl list. A normal
completion supplies the same result as `child wait`. A native supervision or
I/O failure supplies `status oserror` and a diagnostic in `message`.
Callback errors go to Tcl's background error handler. A channel-mode caller
continues to drain stdout and stderr through EOF, including bytes buffered in
Tcl when the completion event arrived.

An explicit wait leaves the notification queued. Closing the token or deleting
its interpreter cancels a pending notification. The callback can close its own
token. Run the normal Tcl or Tk event loop to receive notifications.

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

<a id="present"></a>
### present

#### Synopsis

`child present token ?-class name?`

#### Arguments and options

Pass a token returned by `child start -window visible` (or `normal`). The optional Windows
window class name is an exact, case-insensitive match. It accepts 1 to 255
UTF-16 code units and excludes embedded NUL.

#### Results

The result contains `status` (`pending` or `ready`) and five booleans.

| Key | Meaning |
|---|---|
| `visible` | Windows marks the selected window visible. |
| `iconic` | The window is minimized. |
| `cloaked` | The desktop compositor has cloaked the window. |
| `onScreen` | At least 32 by 24 pixels intersect a monitor's work area. |
| `foreground` | The selected window is the foreground window. |

A visible, restored, uncloaked window with usable on-screen geometry is
`ready`. It can be ready while another application has foreground focus.
When no eligible window is found, the result is `pending` with all five flags
false. This also covers a supervised tree whose windows have all exited.

#### Errors

A closed or foreign token reports `CHILD nohandle`. A token started without
`-window visible` or `normal`, or an invalid class value, reports `CHILD badvalue`.
Malformed options report `CHILD usage`. Windows query errors can report
`CHILD oserror`.

#### Lifetime and timeouts

Each call checks the current input desktop once. For an eligible, uncloaked
window, presentation may request a restore, move an off-screen window onto
its nearest monitor, and request foreground attention. A GUI can poll from an
`after` callback while the application creates its first window. Once a
presentation attempt is complete, later calls on that token observe the
window, respecting any subsequent action by the user.

#### Examples

```tcl
set c [child start -window normal -- editor.exe document.txt]
set view [child present $c]
if {[dict get $view status] eq "pending"} {
    puts "Waiting for the editor window"
}
```

#### Constraints

Selection is limited to ordinary top-level application windows in this
token's Windows Job Object. By default the window must already be visible.
An explicit class can also select a hidden application window. A cloaked
window is reported as observed on the current desktop. Windows controls
foreground activation and may signal attention through the taskbar.

#### See also

`machteld/command/child#start`, `machteld/command/child#info`.

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

<a id="shutdown"></a>
### shutdown

#### Synopsis

`child shutdown token`

#### Arguments and options

Pass the token for a supervised child.

#### Results

Returns a dict. `windows` counts the ordinary top-level windows on the
caller's desktop to which Machteld posted `WM_CLOSE`. They must belong to
the token's job, including its descendants. `stdin` is true if Machteld
closed the token's open channel-mode stdin. Closing follows Tcl's normal
flushing rules. The stdout and stderr channels remain available.

#### Errors

A released or foreign token reports `CHILD nohandle`. Windows enumeration
or message-delivery failures can report `CHILD oserror`. A channel transform
can return its own error while closing stdin.

#### Lifetime and timeouts

Shutdown requests a cooperative exit. A GUI may ask the user to save or
decline. A worker can finish its current request on stdin EOF. The token
remains live for completion notification, wait and close. Repeated calls
return the recorded request. If neither endpoint existed, a later call
can retry after the application creates its window.

#### Examples

```tcl
set request [child shutdown $c]
if {[dict get [child wait $c -timeout 2s] status] eq "running"} {
    child kill $c
}
```

#### Constraints

An existing start-time deadline still applies. An application with its own
shutdown protocol can write its final request before closing stdin. Use
`-onexit` and an `after` timer when a Tk application needs to remain
responsive while waiting.

#### See also

`machteld/command/child#wait`, `machteld/command/child#kill`.

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

The query neither waits nor changes ownership. In channel mode, fields retain
the original channel names even after the script closes one. A name can later
be reused for an unrelated channel; it is not proof that the child still owns
that channel. Child cleanup tracks channel identity and does not close a
replacement merely because its name matches.

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

The owning Tcl interpreter also owns the supervised jobs. Deleting that
interpreter terminates its remaining trees even when the host process continues
running. Process exit provides the same cleanup backstop. Neither path proves
that an interrupted child performed no side effects; reconcile externally
visible state before deciding to replay work.

#### See also

`machteld/command/scope`.

## See also

`machteld/command/run`, `machteld/command/wait`,
`machteld/command/scope`, `machteld/guide/execution-model`.
