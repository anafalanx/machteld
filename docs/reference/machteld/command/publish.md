---
id: machteld/command/publish
type: command
title: publish
summary: Atomically create or replace a Windows file with a prepared file or a Tcl value.
commands: publish, publish file, publish bytes
---

# publish

## Synopsis

```tcl
publish file path stagedFile ?-flush?
publish bytes path value ?-flush?
```

## Arguments and options

`path` is the destination. Both subcommands require an existing parent
directory on the native Windows filesystem. An existing destination must be
a regular file. Close the prepared file before publishing it. Keep other
writers away from that file until the operation returns.

With `-flush`, Machteld reopens the published file, checks its identity and
asks Windows to flush its buffered data to storage. A successful call returns
after Windows acknowledges that request. Another publisher may subsequently
replace the file. The storage device determines persistence across power loss.

## Results

Returns the destination path as supplied. A successful first publication
creates it. A successful replacement switches the destination name to the
completed file in one Windows operation. Concurrent successful publishers can
replace each other's results.

## Errors

`{MACHTELD PUBLISH usage}` reports an unknown subcommand or wrong argument
count. `{MACHTELD PUBLISH badvalue}` reports invalid paths, a missing or
unsuitable staged file, or a source and destination referring to the same
file. `{MACHTELD PUBLISH oserror}` reports a write, close, access, or Windows
publication error.

`{MACHTELD PUBLISH unconfirmed}` means the switch succeeded and the flush
could not be confirmed. The diagnostic includes the Windows error number.
A competing replacement can cause this outcome. Check the destination
before retrying. The staged name was consumed by the publication.

A failure before the switch preserves an existing destination. If Windows
partially completes a replacement and cannot restore the old file to its
name, the diagnostic gives the recovery path containing its prior bytes.
Retain that diagnostic. Cleanup of a recovery backup after successful
publication is best effort.

## Lifetime and timeouts

The call is synchronous and has no deadline. For large streamed data, write
and close a staged file on the destination volume, then use `publish file`.

## Examples

```tcl
set settings [file join $directory settings.json]
publish bytes $settings [json encode -dict [dict create title "Résumé"]] -flush
publish bytes [file join $directory token.bin] [binary decode hex 00ff80]
publish file [file join $directory report.csv] $completedReport
```

## Constraints

The namespace switch makes each completed file visible as a unit. Power-loss
durability depends on Windows, the filesystem and the storage device. An open
destination handle that denies replacement can prevent publication.

## Subcommands

<a id="file"></a>
### file

#### Synopsis

`publish file path stagedFile ?-flush?`

#### Arguments and options

`stagedFile` must be a regular native file on the same volume as `path`.
Both immediate parent directories must be ordinary directories. File
identity checks reject aliases of the destination.

#### Results

Moves the staged file into place and returns `path`. A successful call
consumes the staged name.

#### Errors

Reports `badvalue`, `oserror` or `unconfirmed` as described above.

#### Lifetime and timeouts

The caller owns its prepared file before publication and any staged file
still present after failure.

#### Examples

`publish file final.csv completed.tmp`

#### Constraints

The operation moves the completed file. Finish generating and validating
its contents first.

#### See also

`machteld/command/publish#bytes`.

<a id="bytes"></a>
### bytes

#### Synopsis

`publish bytes path value ?-flush?`

#### Arguments and options

A Tcl bytearray contributes its exact bytes. Any other Tcl value contributes
its UTF-8 text. The operation adds no BOM, line ending or terminator. A NUL
character in text becomes one zero byte.

#### Results

Creates a new temporary file beside `path`, writes and closes it, then
publishes it. Returns `path`.

#### Errors

Reports `badvalue`, `oserror` or `unconfirmed` as described above.

#### Lifetime and timeouts

The command owns the temporary file and attempts to remove it on failure. A
process crash or a filesystem refusal can leave the temporary file on disk.

#### Examples

`publish bytes settings.txt "language=nl\n"`

#### Constraints

The complete Tcl value is already in memory. For a specific external text
encoding, pass the bytearray returned by `encoding convertto`.

#### See also

`machteld/command/publish#file`.

## See also

`machteld/command/hash`, `machteld/command/store`, `machteld/guide/contract`.
