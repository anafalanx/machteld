---
id: machteld/command/audio
type: command
title: audio
summary: Decode compressed audio, play PCM on Windows, and extract audio from HLS playlists and transport streams.
commands: audio, audio decoder, audio output, audio playlist, audio demux
---

# audio

## Synopsis

```tcl
audio decoder mp3|aac
audio output sampleRate channels
audio playlist baseUrl bytes
audio demux transportStreamBytes
```

## Arguments and options

Pass binary data as Tcl byte arrays. PCM uses interleaved IEEE float32
little-endian samples. One frame contains one sample for each channel.

## Results

A decoder or output is an interpreter-owned command handle. Playlist parsing
and transport demultiplexing each return a dictionary.

## Errors

Native errors use the `MACHTELD AUDIO` domain with codes `format`, `limit`,
`state`, `device`, `oserror`, `unavailable` or `unsupported`.

## Lifetime and timeouts

Close each handle after use. Windows renders on its own audio thread. An
application can inspect playback status from Tk while the device is running.

## Examples

```tcl
set output [audio output 48000 2]
$output write [binary format x16000]
$output finish
# Poll [$output status] from a timer until state is done, then close.
```

## Constraints

AAC decoding uses the installed Windows Media Foundation AAC transform.
WASAPI playback requires an available output endpoint.

## Subcommands

<a id="decoder"></a>
### decoder

#### Synopsis

`audio decoder mp3|aac`

#### Arguments and options

Use `mp3` for MPEG Layer III and `aac` for ADTS-framed AAC-LC or HE-AAC.
Call `$decoder feed bytes` to append the next compressed chunk.

#### Results

`$decoder read` returns a dictionary. State `data` includes `pcm`, `format`
(`f32le`), `rate` in Hz and `channels`. State `more` asks for another chunk.
The returned rate reflects the decoder output, including HE-AAC upsampling.

#### Errors

A read can report a malformed or incomplete stream. The `limit` code means
the compressed input queue would exceed 256 KiB. Drain PCM before feeding again.

#### Lifetime and timeouts

After the last feed, call `$decoder finish` and read until `eof`. Use
`$decoder close` to release a decoder at any point.

#### Examples

```tcl
set d [audio decoder aac]
$d feed $adtsBytes
$d finish
while {[dict get [set frame [$d read]] state] eq "data"} {
    consumePCM [dict get $frame pcm] [dict get $frame rate] [dict get $frame channels]
}
$d close
```

#### Constraints

The caller owns each returned PCM buffer. Retain only the frames needed by the application.

#### See also

`machteld/command/audio#output`.

<a id="output"></a>
### output

#### Synopsis

`audio output sampleRate channels`

#### Arguments and options

Choose 8,000 through 192,000 Hz and one through eight channels. Submit
whole interleaved frames with `$output write bytes`.

#### Results

`write` returns the number of bytes accepted. Keep the suffix and retry from
a timer if the bounded queue filled. `$output status` gives `state`,
`queuedFrames` and `acceptedFrames`. States include `opening`, `ready`,
`playing`, `done`, `stopped` and `error`. The last includes a message.

#### Errors

Windows can report a device failure while initializing or during playback.
After a device error, a subsequent write raises `AUDIO device`.

#### Lifetime and timeouts

`finish` drains accepted audio and releases the endpoint before reporting
`done`. `stop` requests cancellation and releases the endpoint before reporting
`stopped`. `close` removes the Tcl handle and requests cancellation.

#### Examples

`set accepted [$output write [dict get $frame pcm]]`

#### Constraints

The queue holds approximately half a second, rounded up to a power of two
in samples. The Windows shared-mode mixer performs device-rate conversion.

#### See also

`machteld/command/audio#decoder`.

<a id="playlist"></a>
### playlist

#### Synopsis

`audio playlist baseUrl bytes`

#### Arguments and options

Supply the final HTTP or HTTPS URL and playlist bytes so relative resource
references resolve against the response.

#### Results

A `master` result lists `variants` with URLs, codecs and bandwidths. A
`media` result lists `segments` in order with URLs, sequence numbers,
durations and discontinuity flags, alongside `target` and `ended`.

#### Errors

Malformed playlists, unsupported encryption, fragmented MP4 and byte-range
segments raise structured errors.

#### Lifetime and timeouts

Parsing is local and completes before returning.

#### Examples

`set segments [dict get [audio playlist $url $bytes] segments]`

#### Constraints

A playlist is limited to one MiB, 256 variants and 4,096 segments.

#### See also

`machteld/command/hls#start`.

<a id="demux"></a>
### demux

#### Synopsis

`audio demux transportStreamBytes`

#### Arguments and options

Pass a complete MPEG-TS segment with its program association and map tables.

#### Results

The result contains a binary `data` elementary stream and the `codec` value
`aac` or `mp3`, suitable for `audio decoder`.

#### Errors

Missing or damaged audio packets and unsupported stream types raise errors.

#### Lifetime and timeouts

Each call processes one bounded segment in memory.

#### Examples

`set audioData [dict get [audio demux $segment] data]`

#### Constraints

The input must contain whole 188-byte packets and fit within 16 MiB.

#### See also

`machteld/command/hls`.

## See also

`machteld/command/hls`, `machteld/command/http#stream`.
