---
id: machteld/command/dirs
type: command
title: dirs
summary: Walk a Windows directory tree deterministically without following name-surrogate links.
commands: dirs
---

# dirs

## Synopsis

```tcl
dirs root ?-depth nonnegativeInteger? ?-prune patterns?
```

## Arguments and options

- `root` must resolve to a directory. A reparse-point root itself is entered
  because the caller named it; name-surrogate descendants are not followed.
- `-depth n` bounds descent. Omitting it allows unlimited descent. A depth of
  `0` inspects only the root using metadata access, including when its ACL
  denies directory listing. Its `links` rows disclose any observed root
  reparse tag, including non-name-surrogate tags.
- `-prune patterns` takes a Tcl list of case-insensitive `string match` patterns
  applied to each entry's base name. A matched directory is not entered.

## Results

Returns a dict with `root`, ordered `paths`, directory count `dirs`, link
decisions `links`, nonfatal `errors`, and the completeness facts `pruned`,
`depthlimited`, and `maxdepth`. Link rows disclose path, reparse tag, whether it
is a name surrogate, and the action taken. Error rows contain path, Win32 code,
and reason.

## Errors

Raised codes are `DIRS badvalue`, `DIRS notfound`, `DIRS oserror`, and
`DIRS usage`. Errors encountered below a valid root are normally disclosed in
the result's `errors` list instead of aborting the whole survey.

## Lifetime and timeouts

The walk is synchronous, retains no handles after return, and has no timeout.

## Examples

```tcl
set survey [dirs C:/src -depth 5 -prune {.git node_modules out}]
if {[dict get $survey errors] ne {}} {
    puts stderr "tree was not completely readable"
}
foreach path [dict get $survey paths] { puts $path }
```

## Constraints

The returned answer is a snapshot assembled during traversal, not an atomic
filesystem transaction. Inspect `errors`, `pruned`, and `depthlimited` before
treating it as complete. Prune patterns match names, not full paths.
The full result is materialized in memory, with no row/byte limit or streaming
cursor. Depth and prune choices reduce traversal, but a single very wide
directory can still be large. Use a supervised worker for expensive surveys
when the host's event loop must remain responsive.

## Single-directory entries and local-only reads

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

## See also

`machteld/command/links`, `machteld/command/canon`,
`machteld/command/watch`.
