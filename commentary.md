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

### 2026-11-24 · machteld 22 candidate (3fb3367), signed 0.21 host · comment · Codex, background jobs

Project Inspector already handled sustained child output, cancellation and
window closure. Its reusable part was the code that owns the child, drains
both streams and gives Tk time to paint. Testing the extracted package on
Windows Server 2025 exercised 3,000 UTF-8 records and a cancel-and-restart
inside the output callback. The application's record validator could stay
in its own model.

### 2026-11-24 · machteld 22 candidate · comment · Codex, SQLite

The upstream Tcl binding and the key/value store can share the single pinned
SQLite engine. A Tcl 9.0.4 fixture exercised transactions and verified that
closing a SQL connection leaves an open store usable. The development branch
now checks both interfaces and runs a bound query in each relocated wrapper.

### 2026-11-24 · machteld 22 candidate · comment · Codex, GUI database lookups

An indexed page can finish before a test exercises cancellation. Taking an
exclusive SQLite lock from a separate fixture connection makes the worker
wait inside a real read and gives the test a reliable point to cancel or close
the window.

### 2026-11-27 · machteld 30 candidate (905d350) · comment · Codex, application references

I searched a packed application's Markdown for a word typed with a combining
accent. Splitting the query into words in Tcl made the spelling miss its own
page. The bundled SQLite FTS5 tokenizer recognized both spellings.
Using it for the query and the index lets a recipient find the page offline.

### 2026-11-27 · machteld 30 candidate (baeecad) · comment · Codex, typed SQL reads

Reading a nullable note showed why the SQLite binding exposes each cell's
storage class. With `db eval -typed`, an empty result, a row containing NULL,
and a row containing empty text reached a packed application as three distinct
values. Statement inspection also caught a misspelled output label when the
query returned zero rows.

### 2026-11-27 · machteld 30 candidate (baeecad) · comment · Codex, transactional imports

I imported two observations of the same item, then replayed a batch with
its JSON fields in a different order. The replay added zero claims. A later
batch inserted a valid observation before its second observation failed an
interval check. Querying from a new process showed only the original claims.

### 2026-11-27 · Machteld 0.50 development · comment · Codex, mixed applications

The original Tcl callback kept its name, arguments and error code when its
formatter moved to a typed module. Packing exposed a difference in startup
paths. The public archive name stays in `argv0`, while `info script` names
the mounted Tcl file. A small entry script explicitly called the original
main procedure and ran it exactly once in both forms.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, temporal evidence

The same recorded 02:30 selected two different observations when supplied
with two different UTC offsets. With the offset omitted, it stayed
unresolved. Fixed-width fractional seconds also let SQLite distinguish two
adjacent one-nanosecond intervals using its ordinary TEXT comparison.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, named time zones

A clock reading can be missing from the calendar even when the archive
is complete. On 29 March 2026, Brussels clocks skipped 02:30. On
25 October the same reading occurred twice. The timeline example checks
both possible instants against its source observations and uses a recorded
offset to narrow the answer when one is available.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, generic pages

The same lookup returned a station name from one page and the vehicle
identifier `007` from another. The item type followed the value through
the shared function and its choice result. At the Tcl boundary a caller
could request text explicitly and retain both leading zeroes.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, handling results

A packed lookup returned the identifier `007` unchanged. When the source
reported a held item, its caller matched the typed reason and printed
`pending: review`. The same caller handled a missing item separately.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, argument labels

Two station names have the same type. A route declaration with required
`from` and `to` labels rejected a call that swapped them. Its packed
reference displayed both labels and its Tcl command still accepted the
two names in order.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, scoped readers

The first-line preview returns from inside the reader's scope. The library
closes the file before that result reaches its caller, even when decoding
the line fails. Its exported type page identifies the cleanup function.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, following an observation

At 09:15 two source records both described Bay 07 as open. Selecting the
field inspection showed its reference, Card 12. When another observation
entered the diagram, that selection followed its stored identifier through
the new layout. Moving the research instant to 09:30 cleared the selection
at the end of the inspection's validity.

### Locating tools after delivery

2026-11-27 · Codex · 0.50-dev

A project with its Tcl entry in a subdirectory and an executable under
`tools/` kept working after its archive was copied and renamed. Removing
the executable beside the archive reported the missing tool even with a
copy under the caller's directory. The process test also writes binary
output past the host's capture limit on both pipes. Each stream keeps its
own byte prefix and reports truncation after the process exits.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, callable values

A callback captured a map containing the identifier `007`. Its owner then
overwrote that entry. Invoking the callback from Tcl still returned `007`.
The packed program also retained its capture after relocation and an
offline rebuild from the archived sources.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, list values

Two identifiers written as `['007', '7']` reach a Tcl caller as separate
text values. An empty inner list in `[[], [7]]` takes its integer element
type from the second row. The same `len` call counts rows in this table,
octets in a file or Unicode code points in a decoded name.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, shared state

Two callbacks registered against the same value returned different
answers. The first retained the original `007`. The second captured an
explicit reference and observed two later updates during event delivery.
After the owning block returned, invoking the retained callback reported
an expired reference.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, inspecting binary measurements

One tenth stays exact when written as `0.1`. Converting it explicitly to
binary64 and back exposes the extra decimal digits of the stored measurement.
The calibration example reads a gain and offset from JSON. Its multiplication
can report overflow before the offset is applied.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, ordered conditions

The two UTC instants for a repeated Brussels clock reading sort in
chronological order. A text identifier keeps its leading zeroes when
compared with another identifier. A condition can test a prerequisite
before calling a fallible function on its right-hand side.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, source diagnostics

One project check now reports mistakes in two separate functions in the
same file. A line beginning with `fn` inside a multiline string still
belongs to the string. An importer can report its own misspelled binding
while the imported file is being repaired.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, child output as it arrives

A child can finish while Windows still has bytes ready on its output pipes.
The streaming test enters a nested event loop inside a two-byte callback and
checks the last byte of each pipe before reporting the child's exit. A second
child fills both pipes with over a megabyte of binary data before reading its
input. Every byte reaches the correct stream in order.

### Waiting for a lookup after its window closes

2026-11-27 · Codex · 0.50-dev

A suspended lookup handler can outlive the interval between its child's
reply and Tcl's next callback. Closing the owner in that interval ran the
handler's cleanup and prevented a late update. A separate handler could
still collect the same reply when the application owned the work. The
regression forces this ordering with a real worker and repeats it after
copying and renaming the application archive.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, keeping the next error location

Omitting a function body can put its diagnostic on the next function's
`fn`. That function is checked again from its first token. An editor can
now show the missing body and a separate error later on the same line.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, constructing a lookup request

A caller can build a lookup request directly from the text identifier
`007` and an integer limit. A missing optional note stays absent in the
serialized request. When the caller edits a received request with `with`,
fields supplied by a newer writer survive the edit.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, building a list of selected rows

A function can now collect rows that meet a condition using a typed empty
list and an append inside a loop. The compiler emits Tcl's local list
append instruction when a function assigns the new list back to its
original binding. A callback that captured the earlier list still sees
its old contents. Optional and required index reads distinguish a missing
row from a present row with an empty text value.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, typed Tk

The X-owned research window displays the same Graphviz drawing as its
Tcl counterpart. A headless test delivered clicks on a polygon and its
text. Both selected the same source record. Redrawing replaced the canvas
items and restored the highlight from the stored occurrence key.

The recording toolkit also delivered a button press to a real worker.
The label stayed at its initial value while the worker waited. Its reply
updated a live window. Closing a window with work outstanding stopped its
worker and both stream children, including one started in a chunk callback.
An application-owned worker kept running, and another handler collected
its reply. The tests exercise the source project, packed archive and
offline rebuild.

A second recording window refreshed while a writer waited for a worker,
and again after its reply handler failed. The diagnostic sink observed the
original error code, source and a rolled-back SQLite write. An application
can present that report in its own status pane without Tk opening a modal
background-error dialog.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, checking intact declarations

A malformed function can sit between two independent mistakes. Checking
now reports errors in complete declarations on either side and checks calls
to their exports from other modules. The checker remembers which names it
could read in damaged declaration heads, so a caller can fix an unrelated
misspelling in the same pass.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, checking an edit

Checking an edit used to generate the Tcl program and discard it. The project
driver now stops after checking the selected entry and its modules. A fixture
disables the emitter and checks projects with both typed and Tcl entries.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, migrating a database in X

A migration can now create a table and its trigger, insert a bound value,
and return the generated key in one typed transaction. SQLite applies a
write before it yields the first `RETURNING` row. If the application asks for
one row and gets two, both inserts and their audit-trigger entries roll
back. A second connection in the regression test checks the database after
the application handles that error.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, binding a mixed Tcl/Tk callback

A Tcl/Tk button can call `workers event` to run an X operation in its
window's scope. One test makes the operation fail immediately and another
lets it reach a worker reply first. In both cases a second window can
refresh its display, and the fault reaches the application's reporter once.

### 2026-11-27 · Machteld 0.50-dev · comment · Codex, checking existing rows during migration

Adding a constrained column checks the values that existing rows would
receive. If one fails, SQLite reports the constraint and the typed
transaction rolls back the migration. A repeated FTS5 table declaration
also preserves the existing index. The regression opens both an authored
archive and its rebuild against a populated index and searches the original row.

<!-- machteld-version-history: end -->

### Build inputs and foreign calls

2026-11-25 · Codex · 0.30 development

The old hosted executable could be reproduced on the build PC by changing
only the manifest object selected by GCC. The build now checks that object's
digest and tests the resource that Windows reads from the resulting executable.

The cffi command reference, concepts, cookbook and introduction come from
four manuals in the pinned source archive. Comparing the raw manual digests
before generation lets a reader retrieve the upstream declarations alongside
the Windows loader and ownership rules that apply in this runtime.
