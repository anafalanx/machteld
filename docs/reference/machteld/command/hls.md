---
id: machteld/command/hls
type: command
title: hls
summary: Follow an HLS audio playlist and receive each new MPEG-TS audio segment in sequence.
commands: hls, hls start
---

# hls

## Synopsis

`hls start playlistUrl commandPrefix`

## Arguments and options

Supply an HTTP or HTTPS playlist URL and a Tcl command prefix.

## Results

Returns a session handle. The callback receives the handle, event name and
event dictionary. A `segment` contains `sequence`, `url`, `duration`,
`discontinuity`, `codec` and binary `data`. An `end` reports the last
sequence. An `error` contains a message and structured error code.

## Errors

Session errors cover network, response status, media format, a missing
sequence in a rolling playlist, or an application callback failure.

## Lifetime and timeouts

The session owns its request and reload timer. Use `$session stop` to
cancel both, `$session status` to inspect progress, and `$session close`
to release it.

## Examples

```tcl
proc receive {session event item} {
    if {$event eq "segment"} {
        processAudio [dict get $item sequence] [dict get $item codec] [dict get $item data]
    }
}
set session [hls start $playlistUrl receive]
```

## Constraints

Supports unencrypted audio in MPEG transport streams. Follow-up requests use
Windows HTTPS certificate validation and automatic proxy discovery.

## Subcommands

<a id="start"></a>
### start

#### Synopsis

`hls start playlistUrl commandPrefix`

#### Arguments and options

The callback runs on the owning Tcl event loop. It can stop or close its
session from inside the callback.

#### Results

The session delivers new sequences in order. Live playlist reloads can
overlap already delivered sequences. Each sequence is emitted once.

#### Errors

A jump beyond the expected sequence ends the session with `HLS gap`. HTTP
failure statuses end the session with `HLS http`.

#### Lifetime and timeouts

The session fetches one playlist or segment at a time. An end list finishes
after the last segment. Live reloads use half the target duration, with a
minimum interval of 500 milliseconds.

#### Examples

`set lastSequence [dict get [$session status] sequence]`

#### Constraints

Master playlists select the variant with the highest advertised bandwidth.
Select an audio rendition URL directly when the master supplies separate
renditions. Native demultiplexing expects a supported audio stream in the
selected MPEG-TS segments.

#### See also

`machteld/command/audio#decoder`, `machteld/command/http#stream`.

## See also

`machteld/command/audio`, `machteld/command/http`.
