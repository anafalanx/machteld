# X compiler workload corpus

The [optimization plan](../../../docs/proposals/x-compiler-optimization.md) explains which workloads to investigate next and how to qualify a change.

The [two-source history workload](history.md) measures an import followed by
as-of and window queries. It compares individual public calls with a typed
batch that validates its input records once.

Run from the repository root with a Machteld runtime that supports X. These examples use the executable produced by the build gate. The runner loads the checkout compiler by default, compiles the X module into memory, and compares its exported functions with independent Tcl implementations. All inputs are deterministic.

~~~powershell
.\out\machteld.exe test/corpus/compiler/run.tcl | Out-Host
.\out\machteld.exe test/corpus/compiler/run.tcl --embedded | Out-Host
.\out\machteld.exe test/corpus/compiler/run.tcl --timings | Out-File -Encoding utf8 timings.tsv
.\out\machteld.exe test/corpus/compiler/run.tcl --compare-with C:/other/packages/application-compiler | Out-File -Encoding utf8 comparison.tsv
~~~

The default run checks both implementations against fixed answers and compares every full-sized X result with Tcl. Map checks compare every key and value. List checks compare every element in order. Any disagreement exits with an error. The fast gate checks the compiler in the source tree. The packaging gate uses `--embedded` to check the compiler inside the candidate executable.

| Workload | Measured input and operations |
| --- | --- |
| `gcd_sum` | Repeated subtraction on 2,048 integer pairs, with a comparison in the inner loop |
| `escape_grid` | A 32 × 24 Mandelbrot grid with an iteration limit of 32 and fallible binary64 arithmetic |
| `histogram` | 4,096 words drawn from 64 case-sensitive keys, with typed map lookup and update |
| `merge_sorted` | Two 512-element sorted lists with ties, checked indexing, optional matching and append |
| `fib` | Fibonacci at 20, two recursive calls per non-base invocation |
| `compact_ids` | 1,024 positive and negative integers wider than 64 bits, including runs of equal values |
| `window_readings` | A half-open interval and exact channel-name filter on 480 records, preserving present readings in input order |
| `snapshot` | Latest available reading for each channel at a cutoff, with tied timestamps, missing readings and keys containing NUL |
| `reconcile` | Closing, lowest and highest balances after 160 signed decimal postings, including cent-level cancellation beyond 2⁵³ |
| `json_intake` | 384 JSON documents, typed record decoding, absent optional adjustments, duplicate keys, missing required fields and malformed rows |

Timing mode emits tab-separated per-call microseconds. Each workload gets 12 paired trials with alternating implementation order, separate batch calibration and a median for each implementation. Batches include the public function call and X argument validation. Input preparation, compilation, output comparison and printing take place outside the timer. Timing values are observations and have no pass threshold.

Use `--compare-with` to time two compiler revisions together. Both compile the
same sources in isolated interpreters. Their generated procedures run on the
same thread alongside handwritten Tcl, in all six possible orders twice.
Divide each round's `baseline` time by its `X` time for the candidate speedup.
The median of those twelve ratios gives each round equal weight. Set
`--compiler directory` or `--embedded` to select the candidate explicitly.

For compiler comparisons, keep the runtime, host, inputs and load conditions consistent and record both compiler revisions. The grid's Tcl reference evaluates ordinary floating-point expressions on the same finite inputs. X also checks intermediate operations and propagates failures. The same numerical answer can carry different runtime costs for these two implementations.

Use `run.tcl --checked-collections --timings` to compare X, ordinary Tcl and
handwritten Tcl with shared boundary checks on the word counter and sorted
merge. The handwritten counter validates the list and normalizes each source
key on both the lookup and update. The handwritten merge validates both input
lists, snapshots list and index in order, and checks every index. The timing
includes those costs. The original Tcl functions and fixed answers verify
each complete result. Add `--compare-with directory` for a four-way trial.

The currency oracle converts two-place decimals into integer cents and accumulates with Tcl bignums. The JSON oracle uses SQLite's JSON parser and explicit schema checks. Its timing includes SQLite query execution. Every distinct JSON document also has a fixed expected outcome, including the distinction between a rejection and an accepted zero.

For a floating-point comparison with X's per-operation checks, run
`checked-grid.tcl` in this directory. Its handwritten Tcl Mandelbrot evaluates
each operation in source order, checks finite results, and canonicalizes zero.
The default run checks counts, numerical behavior, public inputs and failure
locations. It also checks a 14,000-step oscillator against independently written
Tcl, including the number of true comparisons and the exact final bits of both
state variables. Pass `--timings` for twelve interleaved rounds on the grid and
oscillator, reported in separate TSV columns.
`--compiler directory` or `--embedded` selects the candidate and `--compare-with directory`
adds a baseline compiler to the same timed run.

[wire-batch.tcl](wire-batch.tcl) checks and times JSON export using the colleague
import example's real batch and claim types. It measures writing a typed batch
and decoding then writing the same batch. Both paths compare the complete JSON,
including future fields containing nested values, precise number spellings and
an embedded NUL in a member name. Use `--rows 480 --compare-with directory`
for sixteen paired rounds. The same script accepts `--compiler` and `--embedded`.

[sqlite-replay.tcl](sqlite-replay.tcl) runs the typed-import example's complete
SQLite workflow. By default each of two sources sends 240 claims with twelve nested sensor
samples per claim. The runner decodes the north batch, imports north and south,
replays north, and queries entity E7 at times 0, 7, 17 and 20000. It checks
each query result in order. An independent SQLite database built from the
input JSON supplies the expected values for all eight columns of all 480 rows,
including the serialized payload and the number spellings inside its samples.
Use `--rows-per-source count` to change both batch sizes. Every stored claim
and all four query answers are still checked at the chosen scale.

~~~powershell
.\out\machteld.exe test/corpus/compiler/sqlite-replay.tcl --embedded --once | Out-Host
.\out\machteld.exe test/corpus/compiler/sqlite-replay.tcl --compiler packages/application-compiler --compare-with ../baseline/packages/application-compiler --rounds 12 | Out-File -Encoding utf8 sqlite-replay.tsv
~~~

The optional `--tcl-references` flag runs the same imports, replay and time
queries in handwritten Tcl. The reference decodes each saved payload and compares
the full evidence. It also checks both implementations against reordered
JSON members, equivalent number spellings, changed nested evidence, and empty
or malformed saved payloads. A separate SQLite connection checks all eight
columns after a late conflict or consbencht violation. Use `--once` with the
flag for one verification pass, or `--rounds` for timings.

The default checks the checkout compiler once. Use `--timings` to time one
compiler or `--compare-with` to compare two in the same Machteld process.
Timing mode discards one warmup per compiler and alternates their order for
twelve rounds. Each trial starts from a fresh copy of the example schema.
The TSV reports each operation in microseconds. The `whole` row sums both
imports, replay, and four queries. The independent decode, compilation, database
setup, and verification are outside that sum. For each operation, divide the
baseline time by the candidate time within each round and take the median.

[blob-archive.tcl](blob-archive.tcl) reads binary blocks from a generated file,
passes them from Tcl to an exported X function, hashes them and commits them
to SQLite. One mode reads fresh blocks before each transaction and the other
reuses the original bytearrays. A separate reader checks each stored byte,
digest, length, ordinal and SQLite storage class after all three commits. The
fixture covers all 256 byte values, a partial final block, UTF-8 and trailing
NUL bytes. Run the small check with `machteld.exe test/corpus/compiler/blob-archive.tcl --embedded`.
Use `--timings` for six timed rounds after warmup using 128 blocks per transaction.
Adding `--compare-with directory` alternates compiler order in the same host.
The TSV separates import and verification times in microseconds.

The research occurrence workload compiles the diagram application's actual SQL join.
It checks all eight fields and occurrence order against an independent interval
calculation, including an exclusive end, an inclusive start and a late malformed
timestamp. The same fixture imports mixed-offset observations, checks a leap-day
carry and duplicate instants, and verifies rollback after a final invalid offset.
Run `machteld.exe test/corpus/compiler/temporal-rows.tcl --embedded`
for the small check. Add `--compare-with directory` to compare compilers in
twelve alternating pairs on queries returning zero, one and 384 rows. The TSV
reports elapsed microseconds per complete public query. Fixture construction,
result verification and diagram layout are outside the interval. [Workload](temporal-rows.tcl)

The probe coverage workload selects the runs on one laboratory bench and clips probe
assignments from two instruments to each run's half-open query window. Each
source-local observation counts once. A gap means that neither feed records
any probe on that run during the span. An independent Tcl oracle visits every
fixture tick and checks the run IDs, distinct ordered probe IDs, evidence count
and every gap. The default check includes simultaneous runs, overlaps, repeated
observations, an ID conflict, Unicode and empty windows. Run
`machteld.exe test/corpus/compiler/probe-window.tcl --embedded` for the small
check, or add `--timings --runs 64` for twelve complete public queries.
`--tcl-reference` adds an ordinary handwritten Tcl implementation that groups
evidence by run, sorts the clipped intervals and reports gaps between them.
`--compare-with directory` adds a second compiler on the same host. Fixture
generation and result verification are outside the timing. [Workload](probe-window.tcl)

The same check reads an indexed SQLite archive. It asks which evidence covers
a run at a given receipt cutoff. A late file can fill a gap in a past run.
Repeating the query with the earlier receipt cutoff must reproduce the original
gap. It also checks nested intervals, simultaneous runs and empty windows.
[Archive query](probe-window.src) · [Two-feed fixture](probe-archive.tcl)

The document selection workload checks half-open character ranges against a retained
Unicode document. It compares the accepted count, the sum of the selected widths
including overlaps, and every rejected position in input order. The small default
covers an empty document, an astral character, a combining mark, an embedded NUL,
UTF-8 byte length, a retained typed JSON handle and malformed first, middle and
last records. Both the checkout and embedded compiler run it in the gate.
Use `--timings` for twelve warm rounds of 384 selections on documents of 28,
3,584 and 114,688 characters. `--compare-with directory` interleaves a baseline
on the same host. To compare native and portable length handling, run the same
`--compiler directory` on hosts with and without the native helper. [Workload](document-selections.tcl)

The calibrated series workload reads signed SQLite REAL measurements and nullable
biases, applies the calibration example and selects values at or above a threshold.
An integer oracle constructs all expected binary64 words by shifting the exponent.
It checks every queried value, the optional tag, every selected ID and the bits of
each calibrated result. The `selected_rows` case also passes independently constructed
Tcl records into the exported X analysis. Run `machteld.exe test/corpus/compiler/calibrated-series.tcl
--embedded` for the small check. Use `--timings` for twelve alternating rounds
at zero, 256 and 8,192 rows. Adding `--compare-with directory` runs the two
compilers on the same host and also enables timings. The TSV reports elapsed
microseconds for the full public call. Fixture construction and result verification
take place outside the measurement. [Workload](calibrated-series.tcl)

The numeric map workload returns all keys in order and reads all observation
values in that order. Its expected order is constructed from increasing
magnitudes, including 181-digit integers and decimals that differ beyond
binary64 precision. Run with `--embedded` to exercise the packaged compiler.
`--compare-with directory` measures two compilers over twelve alternating
rounds and checks every output after each public call. [Workload](numeric-order.tcl)

The invoice ledger sums quantities after returns and the value of each line at
its unit price. It also reports the smallest and largest net quantities. An independent integer
oracle verifies the resident Tcl-to-X call and the full SQLite report on empty
input, ordinary quantities, near-cancelling quantities with 36-digit coefficients and small fractions
at 43 decimal places. A malformed final stored quantity must fail the report.
Use `--embedded` to check the packaged compiler. Use `--timings` for twelve
rounds at 1,536 invoice lines or `--compare-with directory` to alternate two
compilers on the same host. [Workload](invoice-totals.tcl) · [X report](invoice-totals.src)

To extend the corpus, add an exported function to [kernels.src](kernels.src), its Tcl reference to [reference.tcl](reference.tcl), and deterministic inputs with a fixed answer to [cases.tcl](cases.tcl). For map and list results, add the workload name to the corresponding full-value comparison in [run.tcl](run.tcl).
