---
id: machteld/package/files
type: package
title: Windows directory entries and local-only file reads
summary: List Windows metadata in one pass and read fully resident file contents without cloud hydration.
commands: machteld::files, ::machteld::files::entries, ::machteld::files::openlocal, files entries, files openlocal, machteld::files::entries, machteld::files::openlocal
---

# Windows directory entries and local-only file reads

## Usage

`package require machteld::files 1.0` loads the following commands in a
trusted interpreter. Both require native Windows paths.

* `::machteld::files::entries directory ?rowCommandPrefix?` enumerates the
  immediate children, including hidden files, junctions and cloud placeholders.
  The operation reads native directory metadata once and opens no child file.
  Each dictionary contains `name`, `size` in bytes, `mtime` in whole Unix
  seconds, `filetime` as the original Windows modification time in 100 ns
  ticks since 1601, the raw Windows `attributes` and `reparsetag` integers,
  and the booleans `pinned` and `offline`. The latter includes the offline
  and recall-on-access flags. An omitted command prefix returns a list in
  filesystem enumeration order. A supplied prefix receives one row per call
  and a successful operation returns the count. The callback form bounds
  retained enumeration memory independently of directory size. Callback
  errors propagate. A concurrent directory change can affect the observations.
* `::machteld::files::openlocal path` returns a read-only, seekable Tcl
  channel configured for binary data. Close it when finished. The call checks
  current file metadata and verifies the actual data handle after opening it.
  A cloud placeholder must be fully resident. An incompletely resident file
  raises `{MACHTELD FILES offline}` before returning a channel. The native
  read handle excludes writes, replacement and the exclusive access Windows
  requires for dehydration until close. A conflicting writer reports `busy`,
  missing paths report `notfound`, and an access refusal reports `denied`.
  An unrecognized reparse point reports `unsupported`. Applications can use
  ordinary Tcl `open` to allow Windows to fetch content on demand.

```tcl
package require machteld::files
proc catalog {row} {puts [list [dict get $row name] [dict get $row size]]}
::machteld::files::entries $directory catalog
set f [::machteld::files::openlocal $path]
try {set first [read $f 65536]} finally {close $f}
```

## Errors and lifetime

An empty callback prefix or invalid native path raises `MACHTELD FILES badvalue`. Other failures use the `MACHTELD FILES` domain with `notfound`, `denied`, `busy`, `offline`, `unsupported` or `oserror`. Read the status of the actual open even after listing the directory. Once open, the channel holds its native data handle for the entire reading interval. The caller closes the channel, including on a read error. Both enumeration and reads run on the calling thread. For recursive directory discovery use `machteld/command/dirs`.
