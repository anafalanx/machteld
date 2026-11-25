---
id: machteld/package/encoding
type: package
title: Detecting text encodings
summary: Identify a likely encoding from original file bytes and handle ambiguous input.
commands: machteld::encoding, ::machteld::encoding::detect, encoding detect, machteld::encoding::detect
---

# Detecting text encodings

## Usage

`package require machteld::encoding 1.0` loads `::machteld::encoding::detect bytes` in a trusted interpreter. Pass a bytearray, such as the result of reading a binary channel. The call examines at most the first 1 MiB. It returns immediately after detection and preserves the bytes.

| Result field | Meaning |
| --- | --- |
| `status` | `match`, `nomatch` or `unavailable`. Empty and printable ASCII samples return `nomatch`. |
| `encoding` | ICU label on a match, otherwise the empty string. |
| `confidence` | ICU estimate from 1 through 100 on a match, otherwise 0. |
| `samplebytes` | Number of bytes examined. |

A match is an estimate. Applications choose the confidence threshold and map the label to an encoding supported by their Tcl build. Keeping the original bytes lets a user choose a different decoder. `unavailable` means the required Windows ICU functions could not be loaded.

## Example

```tcl
package require machteld::encoding 1.0
set ch [open $path rb]
try {set sample [read $ch 1048576]} finally {close $ch}
set detection [::machteld::encoding::detect $sample]
puts [list [dict get $detection status] [dict get $detection encoding] [dict get $detection confidence]]
```

## Errors and lifetime

A nonempty Tcl string raises `MACHTELD ENCODING badvalue`. A failure to allocate the native detector raises `MACHTELD ENCODING oserror`. Each call releases its detector before returning. To avoid fetching online-only files when obtaining the bytes, use `::machteld::files::openlocal` from `machteld/package/files`.
