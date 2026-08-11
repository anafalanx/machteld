# mirror's inner loop — measured

**Question.** Before porting `z mirror` (4,527 lines) to Tcl+C, find out whether
its per-entry work is a shape Tcl+C can host, or whether it would end up as a C
program with a Tcl configuration file — in which case Go was the better host and
mirror should stay in z.

**Answer.** It is not a Tcl-versus-Go question at all. The loop is
**syscall-bound**, both languages pay the same syscall, and Tcl's interpreter
contributes 0.3 µs against a ~33 µs system call. The real finding is that
**both z's Go loop and any per-path Tcl loop are ~10–14× slower than they need
to be**, because both ask Windows about one path at a time. machteld already has
the API that does not: `dirs.c`'s bulk enumeration returns every child's
attributes *and* its reparse tag from a single call per directory.

Porting mirror's scan is therefore an **improvement over the incumbent**, not a
compromise — and the C it needs already exists.

---

## What mirror's inner loop actually is

`z mirror` does **not** copy bytes. It drives `robocopy /MIR`, and the copying,
the retrying and the deletion of destination extras are Windows'. What z itself
does per entry is two tree walks:

| | where | per entry |
|---|---|---|
| source link scan | `mirror_links.go` + `mirror_links_windows.go` | `filepath.WalkDir` + `syscall.GetFileAttributes(path)`; for the few reparse points, `CreateFile` + `FSCTL_GET_REPARSE_POINT` + `os.Readlink` |
| destination hazard scan | `mirror_destination_windows.go` | the same, **plus** a `CreateFile` + `GetFileInformationByHandle` per entry to read `nNumberOfLinks` |

The source scan runs **twice per mirror run** — preflight at
`mirror_builtin.go:965`, postflight at `:1193`. So the question is not "can
Tcl+C copy files fast" but "can it host a 300,000-entry classify-every-entry
walk".

Together those files are **374 of mirror's 4,527 lines**. The other 4,153 are
options, path resolution and pinning, run locks, state, artefact indexing,
reports, the restore manifest, and rehearsal — glue, which is the half Tcl is
for.

## The arms

- **A — z's own Go loop.** `discoverMirrorLinks(root)` called directly from a
  harness in a copy of z's source. No robocopy, no mirror run, nothing written.
- **B — pure Tcl.** `glob` per directory (four of them: `-types d`,
  `{d hidden}`, `f`, `{f hidden}`, because `-types d` alone misses the hidden
  *attribute*), then `file type` per entry. `file type` reports `link` for both
  symlinks and junctions, so Tcl can refuse to descend a name surrogate; it
  cannot tell the two apart, which is a fidelity gap, not a speed one.
- **C — C, bulk enumeration.** `dirs.c` with one line changed, so that instead
  of discarding file entries it does to each what a link scanner would: test
  `FILE_ATTRIBUTE_REPARSE_POINT`, read the tag from `EaSize`, classify it.
- **D — C baseline.** `dirs.c` unmodified: file entries discarded.

All timings are the **minimum of three warm repeats**, after a warm-up pass.

## Full tree — `C:\dev`, 21,860 dirs + 280,794 files = **302,654 entries**

| arm | | per entry | vs Go |
|---|---|---|---|
| **A** — z's Go loop | **14,081 ms** | 46.5 µs | 1.0× |
| **C** — C, every entry classified | **986 ms** | 3.3 µs | **14.3× faster** |
| **D** — C baseline, files discarded | **1,013 ms** | 3.3 µs | 13.9× faster |
| **B** — pure Tcl | *abandoned at 20 min* | — | see below |

All three arms that completed found the **same two junctions** — the `winsdk`
payload and a `node_modules` under `_booking` — so this is a like-for-like
comparison of the same answer.

**Classifying every file costs nothing.** 986 ms against 1,013 ms is the
file-classifying build coming out *marginally faster* than the one that throws
files away: the difference is 2.7% and it is noise. The reason is structural —
the file entries are already in the enumeration buffer, and `dirs.c:433` was
discarding data it had already paid to read.

## One warm subtree, all three arms — `.z\r\msys2`, **63,670 entries**

| arm | | per entry | ratio |
|---|---|---|---|
| **A** — Go | 2,112 ms | 33.2 µs | 1.0× |
| **B** — pure Tcl | 6,283 ms | 98.7 µs | 3.0× slower than Go |
| **C** — C | 203 ms | 3.2 µs | **10.4× faster than Go**, 31× faster than Tcl |

## Where the cost is, attributed

Timing each operation separately over a fixed 2,000-file sample:

| | µs per file |
|---|---|
| the Tcl loop itself, no filesystem call | **0.3** |
| `file exists` | 28.7 |
| `file type` | 27.2 |
| `file stat` | 33.2 |
| `file attributes -hidden` | 26.6 |

Every `file` command costs the same, whatever it asks. **The interpreter is
0.3 µs and the system call is ~27 µs** — the language is 1% of the cost, and one
Tcl `file` call costs 8× what the entire C walk spends per entry.

## The measurement that nearly produced a wrong headline

Arm B on the full tree was still running after **20 minutes** against C's
986 ms, with the process showing **40 s of CPU in 16 minutes of wall time** — 3%
CPU, entirely blocked on I/O. The obvious write-up was "Tcl is 1,000× slower
here". It would have been wrong.

Timing first-touch against repeat-touch on the same 20,000 files:

| | µs per file |
|---|---|
| **first** `file type` on a path | **5,984** |
| **second** `file type` on the same path | **46.5** |
| ratio | **128×** |

The 20-minute run was measuring a **cold file cache**, not Tcl. Warm, a Tcl
`file` call and Go's `GetFileAttributes` cost the same to within the resolution
of this experiment (46.5 µs and 46.5 µs on the full tree) — because they are the
same system call with a different spelling in front of it.

This is the fourth time in this project that a cold cache has produced a
confident wrong number, and the first time the discipline caught it before it
was published. What caught it was refusing to accept a ratio without attributing
it: the 0.3 µs loop measurement made "Tcl is slow" impossible to believe.

## Predictions, registered before B, C and D ran

All three held (`PREDICTIONS.md`):

- **B between 0.7× and 3× of Go** — measured **3.0×**, at the top of the range.
- **C under 2,000 ms and ≥7× faster than Go** — measured **986 ms, 14.3×**.
- **D: files near-free in C** — measured **986 vs 1,013 ms**, free.

## What this means for the port

**The reservation is answered, and the answer is the opposite of the worry.**

1. **There is no byte-copying loop to lose.** robocopy does the copying under
   either front door. Nothing about the copy is at stake.
2. **Tcl is not the constraint.** It is 3× Go on this walk, and 99% of that walk
   is a system call neither language chose. Mirror's other 4,153 lines are
   exactly the glue Tcl is good at.
3. **The walk should be C, and the C is written.** `dirs.c` already does the
   bulk enumeration, the `\\?\` prefixing, the surrogate classification and the
   emission order. What a link scanner adds is: stop discarding file entries
   (one line), and read the reparse *target* for the handful of surrogates found
   (two junctions in 302,654 entries — one `CreateFile` +
   `FSCTL_GET_REPARSE_POINT` each, which is noise).
4. **The port would be 14× faster than the incumbent**, on a scan z runs twice
   per mirror run: **28.2 s of z's own per-entry work becomes 2.0 s.**
5. **And it would be more correct in one respect already visible**: pure Tcl
   cannot distinguish a junction from a directory symlink, and the C walk reads
   the tag, so it can.

**Recommendation: port mirror.** Not because Tcl can carry the inner loop — it
can, at 3× — but because the loop belongs in the C that already exists, and
because the thing that makes the port worth doing is that z's scan is using the
wrong Win32 API and the replacement is an order of magnitude faster.

## Reproducing

```bash
tclsh90s.exe tools/build.tcl build/machteld-spike.exe
```

Arm C requires one edit in `src/dirs.c`, in `dirs_children`, replacing

    if (!(e->FileAttributes & FILE_ATTRIBUTE_DIRECTORY)) skip = 1;

with a branch that counts the file, reads `e->EaSize` when
`FILE_ATTRIBUTE_REPARSE_POINT` is set, classifies it with `dirs_isname`, and
*then* sets `skip = 1` — so the walk is unchanged and only the per-file
classification is added. The counters were surfaced through `dirs_dict`. Both
were reverted after measurement; `dirs.c` carries a comment at that line
pointing here.

Arm A needs `zz_mirror_test.go` (in the scratch copy of z's source) run with
`ORACLE_ROOT` set. Arms B and its two isolation harnesses are in this directory
and run under any machteld build.
