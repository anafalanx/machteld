# Two-source history and X entry costs

Run this fixture from the checkout root using a built Machteld executable.

~~~powershell
.\out\machteld.exe test/corpus/compiler/history.tcl | Out-Host
.\out\machteld.exe test/corpus/compiler/history.tcl --embedded | Out-Host
.\out\machteld.exe test/corpus/compiler/history.tcl --embedded --rows 1920 --tcl-references | Out-File -Encoding utf8 checked.tsv
.\out\machteld.exe test/corpus/compiler/history.tcl --rows 480 --compare-with C:/other/packages/application-compiler | Out-File -Encoding utf8 history.tsv
~~~

The default run checks a fixed tie case and generated data at 0, 1, 12, 480 and 1,920 rows. It compares complete results for public Tcl calls into X, a batch of queries inside X, and an X import followed by a batch. The fixture also runs with `--compiler directory` to select a candidate explicitly. Use `--timings` for a single implementation. Adding `--compare-with directory` runs the same inputs and timing thread with both compiler revisions. Set `--rows` to the total input size for that measurement.

The X importer merges two chronological feeds, retaining every observation. At the same tick, it emits all rows from the first feed before rows from the second, preserving order within each feed. For an as-of snapshot, the last present reading wins. An absent reading keeps the previous value. Window queries return every present observation for a channel in the half-open interval. The independent Tcl importer concatenates the feeds and applies a stable sort. Known answers cover ties inside and across feeds, corrections and an absent value after a correction.

Each batch includes seven requests covering empty, short and full scans. Cases include repeated ticks, signed values, case-sensitive names, Unicode, an empty name and an embedded NUL. The public exports and their zero-returning counterparts must reject the same invalid values with the exact Tcl error code and field path. A malformed final row must be detected even when the query would stop at its first row or the X batch has no requests.

Use `--shape distinct` to grow the snapshot by one key per row or `--shape dense` to collect every selected row in a single channel's window from tick zero. These distributions exercise accumulating maps and lists over a range of sizes. The default `mixed` fixture uses five channels, missing readings and short windows. The correctness run includes small cases for all three distributions.

The TSV reports microseconds per invocation. Each `sample` records the round and calibrated batch size. Timed batches rotate through the following paths over 16 rounds. With two compilers the order alternates by round.

| Metric | Operation |
| --- | --- |
| `import` | Merge both raw feeds through one public X call, including validation. The final column gives input rows per second. |
| `snapshot`, `window` | Evaluate a single representative query from Tcl on an already merged list. Each call validates its public inputs. |
| `snapshot_entry`, `window_entry` | Call an X export with the same argument declarations and return zero. The paired ratio to its full query estimates entry cost, including the call and return. |
| `public_batch` | Issue all seven snapshot/window pairs separately from Tcl. |
| `typed_batch` | Issue all seven pairs in one public call. The checked X calls reuse the validated records. |
| `pipeline` | Merge both feeds and issue all seven pairs behind a single public X boundary. |

`public_query` times each of the seven individual snapshot/window pairs over twelve additional rounds. Its median and 95th percentile describe latency across those 84 individual calls. The batch metrics measure the full batch. Fixture generation, compilation, calibration and oracle checks run outside the samples. All data resides in memory. [X fixture](history.src) · [shared query implementations](kernels.src) · [independent Tcl queries](reference.tcl)

[history-checked.tcl](history-checked.tcl) supplies an independent handwritten
Tcl comparison for both public queries. It checks all observation rows before
the cutoff or window can skip any, normalizes arbitrary-precision decimal
integers, and handles missing or tagged optional readings. Its batch entry
validates the observations once for all requested snapshots and windows. The
acceptance run also compares the answers against the ordinary Tcl reference,
which takes canonical observations. The fixture uses well-formed Unicode text,
including channels with embedded NUL characters.

Use `--tcl-references` to time both handwritten implementations alongside X on the same generated observations. The `checked_tcl` and `ordinary_tcl` rows cover the public snapshot, window, seven separately called pairs and individual request latency. The `typed_batch` rows compare X and checked Tcl admitting the observations once. Compare the same metric, input shape and round across implementations. This command measures elapsed microseconds on the local machine. It also works with a second compiler supplied through `--compare-with`.
