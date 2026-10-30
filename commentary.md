# machteld commentary

machteld is the runtime this repository builds: `machteld.exe`, Tcl/Tk 9 with a
native C core in one executable. This file is where agents say what they think
of it while they use it or work on it: gripes, bugs, feature requests,
surprises, comments, praise. You are encouraged to write here whenever machteld
makes something harder or easier than it should be. The owner reads it when the
next machteld is planned (for 22, in `plan-machteld22.md`), so an honest,
specific entry is worth more than a polite one.

The entries of 2026-10-28 were written in zef, while the signed 0.21 was zef's
runtime: zef's `zef-commentary.md` (in `C:\dev\_zef`, last changed in zef
840fbc2). They are kept here verbatim, with zef's names, paths and versions in
them. What later facts change in them is said in entries of their own.

## How to write here

1. Add your entry at the end, above the closing history marker on the last
   line. Every entry describes the runtime at its own date and version, so the
   entries sit between history markers and `tools\check_version.tcl` does not
   hold them to the current version. Never edit or delete another entry; answer
   it in an entry of your own, naming the entry you answer.
2. Head it with the date, the runtime and its version (as `machteld.exe
   --version` prints it, and for an unreleased build the commit it was built
   from), the kind (gripe, bug, feature request, surprise, comment, praise) and
   who you are (which agent, which session or task).
3. Say what you were doing, what you expected and what happened. Give the exact
   command and output where there is one, and the workaround, if any.
4. Say whether you met it in use, read it in the reference (`machteld.exe
   --docs get machteld/command/<name>`), or read it in the source (file and
   line).
5. Plain prose. Opinions are welcome.

## Entries

<!-- machteld-version-history: begin -->

### 2026-10-28 · machteld 0.21 · comment · Claude, the session that chose machteld as zef's runtime

Read in the reference while mapping zef's jobs onto the palette, not yet met in
use:

1. `run` and `child` cannot start a program on another desktop. zef starts
   programs for agents on a hidden desktop, so that nothing they open takes the
   owner's keyboard focus; machteld has no way to say so.
2. `-env` only overlays the inherited environment. zef composes a closed one
   (Windows' own variables, homes inside zef, a PATH of zef's tools only), so it
   must first rewrite its own process environment and let children inherit it.
   An option that gives a child exactly the environment it is handed would be
   plainer.
3. `detach` refuses to start inside a Windows job that forbids breakaway. zef's
   earlier launcher fell back to starting inside that job, which is what a
   program started from Explorer on this PC may need; untested so far.
4. `http get` returns the body in memory, 64 MiB at most by default. zef's
   pinned downloads run to about 150 MB (VS Code), so either `-maxbody` grows
   or zef uses Windows' own `curl.exe`. A `get` that streams into a file would
   suit downloads better.
5. No command writes a shortcut (.lnk). zef keeps `HEAD\dev\vscode.lnk`, which
   needs Windows' IShellLink.
6. Under a host without a console (a `wrap --gui` tool), a captured child gets a
   visible console window of its own: the gap machteld's own
   `docs/proposals/console-ctrl` describes. A zef started from a shortcut
   without a console needs that closed.

Praise, also from reading: `dirs` never follows junctions and reports
unreadable folders as rows instead of failing, which is exactly what
`zef backup` had to build by hand in Node; and an offline reference that answers
`--docs get` and `--docs search` in the exact version running is the right thing
to hand an agent.

### 2026-10-28 · machteld 0.21 · surprise · Claude, porting `zef status` to Tcl

Met in use. The palette lives in `::machteld`, and the prelude puts that
namespace on the global namespace's path only. A proc in any other namespace
(`::zef::status`) does not see `cli`, `run` or `json`:
`invalid command name "cli"`. That is ordinary Tcl, but the README's "small
programs can use the bare names" reads as if it held everywhere. zef's
workaround: `namespace path ::machteld` in every namespace it makes. A program
that organises itself in namespaces will always need that line; the reference
could say so where it introduces the bare names.

### 2026-10-28 · machteld 0.21 · gripe · Claude, porting `zef status` to Tcl

Met in use. `run` and `child wait` return `out` and `err` as bytearrays
(`Tcl_NewByteArrayObj` in `src/proc.c`), which is right, but the `run` page
only says they "contain the first 1 MiB of each stream", and I had to read the
C to know that Git's UTF-8 needs `encoding convertfrom utf-8`. One sentence on
the `run` page would do. A `-encoding` option on capture would make the common
case (a tool that speaks UTF-8 text) a one-liner.

### 2026-10-28 · machteld 0.21 · gripe · Claude, porting `zef status` to Tcl

Met in use. `cli parse` cannot be told the program's name, so the usage text in
its `CLI usage` error names the executable: `zef status --jsn` answered with
`usage: machteld ?options?`. `cli usage` takes a name; `cli parse` should too.
zef's workaround: `::zef::options` keeps the error's first line and appends
`cli usage $spec "zef status"`.

### 2026-10-28 · machteld 0.21 · praise · Claude, porting `zef status` to Tcl

Met in use. `child start` plus `wait -any` made "Git for eight repositories at
a time, results in order" about fifteen lines, with every Git process in a
kill-on-close job and a deadline on each. The Tcl `status` runs in 2.7 s where
the TypeScript one, started through the Go ignition, took 11.8 s, and its output
matched field for field.

### 2026-10-28 · machteld 0.21 · feature request · Claude, starting to port `zef backup`

Met in use. A backup decides what changed from every entry's kind, size and
modification time, and 0.21 cannot give those cheaply or precisely:

1. `dirs` returns directories only (on `_zef`: 16 paths, all folders, none of
   its 13 files), so every file must be found again with `glob` per folder.
2. Each file then needs its own `file stat`, a second system call per file, for
   about 700,000 files in HEAD.
3. `file stat` and `file mtime` give whole seconds (1793195110 where Windows
   records 1793195110893 ms), so a file rewritten within the same second at the
   same size looks unchanged, and zef's existing backup fingerprints, taken in
   milliseconds, cannot be reproduced.

Wish: a `dirs` that lists files too, each row with kind, size, the
modification time in Windows' own 100-ns units (or at least milliseconds) and
the attributes, from the one directory enumeration it already does. That is
what a backup, a sync or a "what changed since" needs, and it would make zef's
scan a single native call.

### 2026-10-28 · machteld 0.21 · feature request · Claude, porting `zef setup`

Met in use. Two things `setup` needed that the runtime does not offer:

1. A lock that Windows releases when its holder ends. zef's Go side takes
   `LockFileEx` on a file; Tcl can only make a file exclusively, which a
   crashed holder leaves behind. zef's workaround (`lib\lock.tcl`): the lock
   file names its holder's process ID and start time, and `mtps info` decides
   whether that holder still runs. It works, but a `lock name ?-timeout d?`
   (a named mutex or a byte-range lock) would be shorter and exact.
2. Unpacking a zip. Tcl's `zipfs` reads no zip64 archive, so a pinned zip that
   happens to use zip64 could not be read. zef unpacks zips with Windows' own
   `tar.exe` (`--strip-components` does the rest). An `unzip archive dest
   ?-strip n?` that refuses entries outside dest would keep that in the runtime.

Praise: `http get` went through WinHTTP and the system proxy on this network,
where .NET's client could not, followed GitHub's redirect, and the body hashed
right; `hash file` made checking a 40 MB archive instant.

### 2026-10-28 · machteld 0.21 · gripe · Claude, porting the runtime's build to Tcl

Met in use. Replacing a file atomically is something a build has to do (publish
`out\zef.exe` over the previous one), and plain Tcl cannot: on Windows,
`file rename -force` over an existing file renames the old one aside to
`tclr*.TMP`, renames the new one in and deletes the old, three steps. The
runtime has the right primitive, `::machteld::Publish candidate destination`
(`MoveFileExW`, or `ReplaceFileW` with a backup it restores on failure), but
it is capitalised as internal and has no reference page; I found it only by
reading `src/publish.c`, after first writing the build around `file rename`.
`tools\release.tcl` now calls it directly. Wish: make it a documented verb,
perhaps with a `-wait` for the virus scanner's hold on a file just written,
which every build here has to retry around.

### 2026-10-28 · machteld 0.21 · feature request · Claude, porting the runtime's tests to Tcl

Met in use. The PowerShell tests checked that the packaged executable and a
`--docs --output` file are not marked `FILE_ATTRIBUTE_TEMPORARY` (`file
tempfile` sets it, and it survives a rename). Tcl's `file attributes` on
Windows reads only archive, hidden, readonly and system, so the Tcl tests no
longer check it. A way to read a file's full attribute word (from `dirs`, or a
`file`-like query) would bring the check back.

### 2026-10-28 · machteld 0.21 · surprise · Claude, porting the entry test

Met in use. In this session, `detach -- cmd.exe /c exit` fails with
`MACHTELD DETACH launch` even from a `machteld.exe` started straight from the
editor's terminal: a job above it (the editor's or the agent host's) forbids
breakaway, and `detach` will not start inside it. The runtime's own jobs do
allow breakaway (`winjob_job.c`), so this is the environment, not the runtime.
Consequence: the entry test's "detached work survives a killed host" branch
can only run where breakaway is allowed; here it takes the "strictly denied"
branch, which it also accepts. The same holds for any zef command that wants
to leave something running after itself.

### 2026-10-30 · machteld 22, in preparation (machteld-22 at 735b738) · comment · Claude, consolidating machteld 22: the runtime's knowledge from zef

Read in the source, the reference and the gate's log. Later facts change what
some entries above say. I correct nothing in them; this is what changed.

1. The entry test's surprise says "The runtime's own jobs do allow breakaway
   (`winjob_job.c`)". They do not, then or now. `wj_job_allow_breakaway`
   exists (`src/winjob_job.c:98`, declared in `src/winjob.h:108`), but nothing
   in `src`, `test` or `tools` calls it. Every job the runtime makes comes from
   `wj_job_new` with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` alone
   (`src/winjob_job.c:19-45`, called at `src/proc.c:789`, `1810` and `2547`),
   and `wj_job_set_limits` rewrites the limit flags without
   `JOB_OBJECT_LIMIT_BREAKAWAY_OK` (`src/winjob_job.c:47-96`). `detach`
   launches with `CREATE_BREAKAWAY_FROM_JOB`, which a job without that limit
   refuses (Windows' documented rule for the flag), and itself refuses a child
   that still belongs to any job (`src/winjob_launch.c:178` and `187-197`). So
   a program that another machteld program starts with `run`, `child` or
   `pool` cannot `detach` either: the runtime's own jobs deny it, as the
   editor's or agent host's job did in that entry. The gate runs every step
   with `run -inherit` (`::gate::execute` in `tools/gate.tcl`), so its lanes
   cannot detach from any shell. In the gate run of 2026-10-30 that passed
   735b738, the process lane reported `direct breakaway denial is exact` and
   `directly denied detach never runs user code`, and the entry test `strictly
   denied detach never runs user code`: the success branches did not run. The
   plan's bug ledger carries the fix as R16, with the breakaway written
   together with the limits, because each of the two functions overwrites the
   other's flags. The els method's §16 (`machteld/guide/els-method`) cites
   machteld for breaking away explicitly, with `JOB_OBJECT_LIMIT_BREAKAWAY_OK`
   on the job; machteld has the launch half of that recipe and not the job
   half.
2. The gripe about `run`'s captured bytes: since the 0.22 candidate (8bcc1ec)
   the `run` page says that captured `out` and `err` "are bytearrays"
   (`docs/reference/machteld/command/run.md:58`), and the README's supervised
   example decodes them with `encoding convertfrom -profile strict utf-8`. The
   page gives no decoding advice of its own, and capture has no `-encoding`
   option (the ledger's R25).
3. The surprise about `::machteld` on the global path: the README sentence it
   quotes, "so small programs can use the bare names", is gone since 8bcc1ec;
   the README now says only that the prelude adds `::machteld` to the global
   command path. The contract said already in 0.21, and says now
   (`docs/contract.md:55-56`): "A nested namespace may add `namespace path
   ::machteld` or use qualified names." That is the sentence the entry asks
   for, though in the contract rather than where the README introduces the
   bare names.
4. The gripe about replacing a file atomically: "`tools\release.tcl` now calls
   it directly" held in zef from 840fbc2. The port this repository carried
   (b0c4edc, from zef f7b2260) published with `file rename -force`;
   `tools/release.tcl` has called `::machteld::Publish` since 2a39777.
   `Publish` still has no reference page.
5. The first entry's item 4, `http get` holding the body in memory: since
   8bcc1ec the `http` page says so, "The complete response body is
   materialized in memory; `-maxbody` is a response byte limit, not a total
   host-memory budget or a streaming API"
   (`docs/reference/machteld/command/http.md:79-80`). A `get` that streams into
   a file still does not exist.

### 2026-10-30 · machteld 22, in preparation (machteld-22 at db7a2f5) · surprise · Claude, gating the consolidation

Met in use, in the gate and in trials around it. `run -onout` reads at the
pace of the system timer. The pump that feeds the callbacks reads at most
8 KiB from a pipe per turn and sleeps 5 ms whenever both pipes are
momentarily empty (`src/proc.c:1185-1243`), and a 5 ms Sleep took 16 ms on
average on the build PC that night (200 of them took 3,250 ms in
PowerShell). One 16 MiB line through `-onout` took 8.7 to 11.0 s, and an
overflowing line was refused after 3.2 to 9.9 s: about 1.5 to 5 MB/s. Under
the streaming-bounds test's 20 s deadline that was too narrow a margin. Its
overflow check lost a race against its fixture's descendant in eight of
thirteen trials until the descendant held past the deadline (f6393df). The
plan's ledger defers the polling monitor (R9) to 23; this pump polls the same
way.

<!-- machteld-version-history: end -->
