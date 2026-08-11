# mirror's inner loop — predictions, registered before the other arms ran

Written after Arm A only, before B, C and D were measured or written.

## What the loop actually is

`z mirror` does **not** copy bytes: it drives `robocopy /MIR`, and the copying,
the retry logic and the deletion of destination extras are Windows'. What z
itself does per entry is two tree walks:

1. `discoverMirrorLinks(source)` — `filepath.WalkDir` over the whole source
   tree; for **every** entry a `syscall.GetFileAttributes(path)`, and for the
   few carrying `FILE_ATTRIBUTE_REPARSE_POINT` a `CreateFile` +
   `FSCTL_GET_REPARSE_POINT` + `os.Readlink`. Run **twice** per mirror
   (preflight at `mirror_builtin.go:965`, postflight at `:1193`).
2. `validateMirrorDestinationHazards(dest)` — the same walk over the
   destination, plus a `CreateFile` + `GetFileInformationByHandle` **per entry**
   to read `nNumberOfLinks` and reject multiply-linked files.

So the question "can Tcl+C host mirror's inner loop" is really "can it host a
300,000-entry classify-every-entry walk", not "can it copy files fast".

## Arm A, measured

`C:\dev`: **21,849 dirs + 280,779 files = 302,628 entries**.

    ARM-A  z's own Go loop   14,081 ms   (2 links found, 0 errors)

46.5 µs per entry, which is enormous for a walk and is the shape of a
**syscall-bound** loop: one `GetFileAttributes` per entry, on top of the
directory enumeration that already returned those very attributes.

## Predictions

**Arm B — pure Tcl** (`glob` + a `file` command per entry): *between 0.7× and
3× of Go*, i.e. **10–40 s**. The reasoning is that this loop is syscall-bound
rather than interpreter-bound, so Tcl's per-operation cost is added to a large
constant instead of dominating one. If Tcl comes out anywhere near Go's number,
that is a real finding: it would mean the language is not the constraint here.

**Arm C — C, bulk enumeration** (the `dirs.c` technique):
**under 2,000 ms, i.e. ≥7× faster than Go.** `GetFileInformationByHandleEx(
FileIdBothDirectoryRestartInfo)` returns every child's attributes *and* its
reparse tag (in `EaSize`) in one call per DIRECTORY. That is ~21,849 calls
instead of 302,628, and `dirs.c:433` is currently throwing the file entries away
after they have already been read into the buffer.

**Arm D — the marginal cost of files in C: near zero.** Deleting the one line
`if (!(e->FileAttributes & FILE_ATTRIBUTE_DIRECTORY)) skip = 1;` should change
the walk's time by much less than the 13× ratio between file and directory
counts, because the bytes are already in the buffer and only the per-child
bookkeeping is added.

If C is ≥5× faster than Go here, the conclusion is not "Tcl is too slow for
mirror" but "**z's link scan is using the wrong Win32 API**", and the port would
be an improvement rather than a compromise.
