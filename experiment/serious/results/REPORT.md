# Serious corpus result: machteld/Tcl versus Python

**Run date:** 2026-07-11  
**Frozen apparatus commit:** `7dadb490853cf45b643aa61390bb9339b609664c`  
**Run-manifest SHA-256:** `1021bcac2f68ee2b5851dbd17d658fa1d68efb01aee5c6a03c972f2719b2093b`

## Result

On this complete 30-task algorithm panel, blind GPT-5 coding agents found
machteld/Tcl and Python equally easy: **90/90 final solutions in each arm
passed every hidden case**. All 30 task-level differences were zero.

The preregistered classification is **practically equivalent**. The posterior
task-weighted solve-rate difference, defined as machteld minus Python, had:

- median: `-0.00009`;
- central 95% credible interval: **`[-0.07489, +0.07480]`**;
- `P(|delta| < 0.10) = 0.990675`;
- `P(delta > 0.10) = 0.004705`;
- `P(delta < -0.10) = 0.004620`.

The observed paired difference was exactly zero. Its within-family paired-task
bootstrap interval was `[0, 0]`, reflecting that every observed task was tied.
The Jeffreys posterior interval, rather than that degenerate bootstrap, retains
uncertainty from having only three fresh subjects per task and arm.

This is also a ceiling result. It demonstrates feasibility and rules out a
large disadvantage on the fixed panel under the preregistered rule; it cannot
rank the languages more finely than roughly the posterior +/-7.5 percentage
point interval.

## Trial accounting

- 30 tasks x 2 arms x 3 trials: **180 fresh agents**.
- Valid completed cells: **180/180**; exclusions: **0**.
- Unique agent identifiers: **180/180**.
- Hidden executions passed: **1,392/1,392 per arm** (464 inherited hidden rows
  repeated across three trials).
- Official visible checks: 178 cells used one; 2 cells used two.
- One-check hidden solves: **89/90 per arm**.
- Attempt snapshots: 182. In the two repaired cells, the first snapshot failed
  and the second/final snapshot passed; every other first snapshot passed.
- Protocol deviations, infrastructure failures, subject wall limits, and
  checker-cap violations: **0**.

The product admitted two concurrent subjects rather than three, so each
three-cell manifest wave ran as 2+1. This stayed inside the frozen "at most
three" rule. Task, arm, and trial order were unchanged. Solver wall time is not
an endpoint and is not compared: the queued third subject's metadata clock
included scheduling delay, and the first two very fast cells used their first
official-check time as a documented start-time proxy.

## Authoring footprint

Because every cell solved, source-size summaries cover the full balanced
matrix:

| Arm | Median UTF-8 bytes | Median nonblank lines | One-check solves |
|---|---:|---:|---:|
| machteld/Tcl | 417.0 | 18.5 | 89/90 |
| Python | 293.5 | 12.0 | 89/90 |

Machteld solutions were therefore about 1.42x the median byte count and 1.54x
the median nonblank line count on these small integer functions. This reverses
the earlier process-control micro-task, where the Tcl solution was smaller;
source footprint is task-domain dependent rather than a universal language
ordering.

## What was tested

The panel reuses all 30 independently validated tasks from the Tika serious
corpus, not a selected subset:

- 12 validator/checksum tasks;
- 7 number-theory/crypto tasks;
- 7 bit/encoding/hash tasks;
- 4 interpreter/state-machine tasks;
- difficulty labels: 4 mid, 18 hard, 8 very-hard.

Both references passed 1,108/1,108 visible-plus-hidden arm/case evaluations
before assignment on the exact checker contract. The generated neutral corpus
preserves every input and expected output while removing implementation advice
specific to Tika or fixed-width arithmetic that is irrelevant to both bignum
arms.

The source corpus contains 464 hidden rows, of which 17 duplicate a visible row
and 2 repeat another hidden row within a task, leaving 445 novel unique hidden
rows. Grading deliberately retained all inherited rows. The primary all-hidden
binary outcome is unaffected, but case counts must not be read as 464
independent novel tests.

## Interpretation and limits

The result is strong evidence that contemporary blind agents can author
correct core-Tcl code for machteld across this integer/bit/validator/interpreter
panel despite far greater Python pretraining exposure. There is no observed
correctness or repair disadvantage here; the cost is moderately larger source.

It is not a general Tcl-versus-Python verdict. These tasks are pure scalar
functions, all use integer inputs/outputs, and the historical Tika run had
already shown a ceiling. The panel does not test stateful string processing,
files, subprocesses, PTYs, Tk, persistence, networking, deployment footprint,
or runtime throughput. Procedural blindness was used because the shared
Windows account could technically access the wider workspace; no subject
reported or exhibited oracle access.

Accordingly, the next prospectively selected evidence is the existing Luax
`kvstore` corpus: nested transactions, lists of command strings, exact parsing,
string output, malformed-input failures, and 59 hidden cases. It is reported as
a separate descriptive supplement rather than retrofitted into this frozen
confirmatory analysis.

## Reproducibility

Machine-readable evidence is in:

- `analysis.json`: fixed 200,000-draw Jeffreys analysis and paired sensitivity;
- `rows.json`: all 180 final-cell outcomes and source metrics;
- `attempt-rows.json`: visible and hidden replay for all 182 snapshots;
- `summary.json`: overall, task, family, and difficulty aggregates;
- `run-manifest.json` and `run-manifest.sha256`: assignment and apparatus lock;
- `subject-metadata.jsonl`: the external subject audit trail;
- `apparatus/`, `cells/`, `attempts/`, and `runtimes/`: exact archived inputs,
  submissions, check records, and executables.

`bundle-manifest.json` inventories and hashes every result file after this
report is finalized.
