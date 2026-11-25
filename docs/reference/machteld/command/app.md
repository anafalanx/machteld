---
id: machteld/command/app
type: command
title: app
summary: Get the command prefix for starting another instance of the current application.
commands: app, app launch
---

# app

## Synopsis

`app launch`

## Arguments and options

`launch` takes no arguments.

## Results

Returns a Tcl list of executable and argument words. Pass it to `child start`,
`run` or another argv-based process launcher, expanding it with `{*}`.
Append the arguments the application should receive. Obtaining the prefix
does not start a process.

## Errors

`MACHTELD APP state` means there is no active application, for example at the
interactive prompt. An unknown operation or extra argument raises
`MACHTELD APP usage`.

## Lifetime and timeouts

A direct script's prefix captures its absolute entry path at startup. Another
instance reads that file again.
Changing the current directory or assigning a different `argv0` does not alter
the prefix.

A `.machteld` application's prefix starts the same archive generation. The
running application and its newly started workers keep their original scripts
and assets when another copy is published at the same location. An ordinary
fresh launch from that location reads the published copy. In either case
`argv0` identifies the original absolute distribution path, and `info script`
identifies the mounted entry.

Each archive process holds a reference to its generation. A worker that has
entered its application can start another worker after its parent exits. When
the last holder exits or is killed, the prefix expires. To hand off to a
detached worker, wait for its application to signal readiness before exiting
the last holder.

## Examples

```tcl
package require machteld
if {$argv eq {--worker}} {
    puts finished
    exit 0
}
set result [run -- {*}[app launch] --worker]
puts [dict get $result out]
```

Inside an application namespace, use the fully qualified
`::machteld::app launch`.

## Constraints

Use the prefix in the same Windows logon session and treat its words as
opaque. It identifies an active archive generation and is unsuitable for
persistent shortcuts. Archive startup needs temporary space for the compressed
archive. Processes share a read-only backing mapping. If a worker starts after
the original temporary name becomes unavailable, archives over 64 MiB need
another temporary copy for Tcl's file-backed ZIP reader. Windows reclaims
these snapshots when their owners release them.

## Subcommands

<a id="launch"></a>
### launch

#### Synopsis

`app launch`

#### Arguments and options

There are no additional words.

#### Results

Returns the current application's command prefix as a Tcl list.

#### Errors

Raises `APP state` outside an application and `APP usage` on extra arguments.

#### Lifetime and timeouts

A pinned archive prefix remains usable while at least one process holds its
generation. The operation has no timeout.

#### Examples

`set token [child start -- {*}[app launch] --worker $input]`

#### Constraints

The application interprets its own worker arguments.

#### See also

`machteld/command/child#start`, `machteld/command/run`.

## See also

`machteld/command/child`, `machteld/command/run`,
`machteld/guide/packaging`.
