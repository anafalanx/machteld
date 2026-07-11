# Blind-agent authoring: machteld/Tcl versus Python

**Study date:** 2026-07-11

## Answer

Within the tested envelope, blind GPT-5 coding agents do **not** find
machteld/Tcl meaningfully harder to make correct than Python. Across four
prospectively frozen experiments, all 102 fresh subjects in each arm produced
final solutions that passed every hidden case. The confirmatory 30-task panel
met its preregistered practical-equivalence rule.

The measurable disadvantage is source footprint, not correctness or repair.
In the serious panel and stateful `kvstore` anchor, agent-written Tcl medians
were about 40-65% larger than Python. The strict micro-pilot parser was a larger
exception (about 186% more bytes and 200% more lines). The ordering is not
universal: on the machteld-specific structured process wrapper, Tcl was 35%
smaller because the runtime API removed Python's subprocess glue and exception
branch.

This supports the central machteld thesis in a bounded but nontrivial form:
agents supplied with a compact, relevant reference can reliably write core Tcl
despite Python's much larger training and ecosystem advantage. It does not yet
show equal unaided API discovery, maintenance productivity, or coverage of the
whole machteld runtime.

## Combined evidence

| Experiment | Scope | Fresh subjects | Final hidden result | Final solves after one official check | Median source observation |
|---|---|---:|---:|---:|---|
| Micro-pilot | `gcd`, strict `sum_ints` | 12 | 75/75 per arm | 6/6 per arm | GCD bytes nearly equal; strict parser Tcl 717 B vs Python 251 B |
| Structured process probe | safe argv/capture/exit/timeout | 6 | 18/18 per arm | 3/3 per arm | Tcl 359 B/12 lines vs Python 556 B/17 lines |
| Serious panel | all 30 Tika tasks | 180 | 1,392/1,392 per arm | 89/90 per arm | Tcl 417 B/18.5 lines vs Python 293.5 B/12 lines |
| Stateful supplement | full Luax `kvstore` task | 6 | 177/177 per arm | 3/3 per arm | Tcl 4,810 B/148 lines vs Python 3,301 B/90 lines |
| **Descriptive total** | **34 task specifications** | **204** | **1,662/1,662 per arm** | **101/102 per arm** | Domain-dependent |

The total is an audit summary, not a post-hoc pooled hypothesis test. It
contains 102 fresh `fork_turns="none"` subjects per arm and 3,324 successful
final hidden executions overall. Exactly one subject per arm needed a second
official visible check, both in the serious panel; every other subject used one
official check and finished hidden-correct. The serious and `kvstore` apparatus
directly hidden-replayed every check-time snapshot. The older pilot and process
probe preserved the one-check audit trail and final hidden grade, but not a
separately hidden-graded check-time snapshot.

## Confirmatory result

The 30-task serious panel is the inferential core because its rule was frozen
before its 180 assignments. It reused the complete Tika serious corpus: 12
validator/checksum, 7 number-theory/crypto, 7 bit/encoding/hash, and 4
interpreter/state-machine tasks, with three fresh subjects per task and arm.

Both arms solved 90/90 cells. The preregistered task-weighted machteld-minus-
Python solve-rate posterior had median `-0.00009`, central 95% credible interval
`[-0.07489, +0.07480]`, and `P(|delta| < 0.10) = 0.990675`. It was therefore
classified **practically equivalent** at the fixed ten-percentage-point margin.
The interval is more informative than the observed difference of exactly zero:
the ceiling still leaves uncertainty of roughly +/-7.5 percentage points.

The complete panel, rather than a favorable subset, was used. Its 464 inherited
hidden rows include 17 visible duplicates and two within-task repeats; all were
retained and disclosed. Both language references passed 1,108/1,108
visible-plus-hidden evaluations, plus 3,600 randomized cross-arm comparisons,
before assignment.

## The stateful result

The serious panel's main weakness was its pure integer-function shape. The
separate `kvstore` supplement reused all three visible and all 59 hidden rows
from the earlier Luax experiment without selecting cases. It exercises exact
ASCII-space parsing, strings, mutable mappings, counts, nested transactions,
rollback, commit, strict signed-64-bit validation, and 25 malformed-input
failures.

All six fresh subjects passed 59/59 hidden rows on their first checked source.
The three Tcl solutions independently included both whole-store snapshot and
undo-map transaction designs. Thus the algorithm-panel ceiling was not merely
an artifact of tiny stateless arithmetic functions.

Tcl remained larger: 1.46 times Python's median bytes and 1.64 times its median
nonblank lines. The sources show a concrete reason. Python agents combined
`re.fullmatch` and `int`; Tcl agents chose explicit ASCII digit and range logic,
and one duplicated that logic. This is an authoring-friction signal even though
it did not create correctness or repair failures.

## What “difficulty” means here

The apparatus can observe final hidden correctness, official visible-check
count, source bytes, and nonblank lines. It cannot observe a stable token count
or the model's internal effort. Subject wall time is not a language-only metric
because concurrency and scheduling are product-level effects. Accordingly:

- **Correctness:** no observed difference; the serious panel supports practical
  equivalence within its fixed margin.
- **Repair through provided feedback:** no observed difference; 101/102 final
  hidden solves after one official visible check in each arm.
- **Code footprint:** Python is usually shorter for conventional parsing and
  algorithms; machteld can be shorter where it provides a higher-level runtime
  primitive.
- **Unaided familiarity:** not measured. Both arms received matched compact
  primers, so the result is “can an agent author this with relevant docs?”, not
  “does the model recall the API from pretraining?”

This distinction matters. The experiments strongly reject the idea that Tcl's
syntax is itself a major barrier to documented agent authoring. They do not
show that sparse machteld documentation, missing examples, or unfamiliar
project conventions would carry no cost.

## Limits and remaining engineering risk

Procedural blindness was used: subjects inherited no conversation, were told
to stay inside one opaque cell, and were given no internet or oracle help, but
the shared Windows account was not an OS sandbox. No contamination was
reported or detected.

The coverage is now broad enough to answer core authoring feasibility, but it
is not a universal language comparison. Still missing are realistic existing-
code maintenance, filesystem workflows, sockets/servers, SQLite-backed
`store`, `child`, PTYs, Tk, packaging, deployment, and long-running service
behavior.

There is also a separate runtime concern from the process probe: when a direct
child exits while a descendant retains a captured pipe, machteld's current
`run -timeout` path can wait beyond its deadline during reader drainage. The
diagnostic requested 1,000 ms and returned after about 3,339 ms. Python's
standard subprocess path has a related descendant-pipe limitation. This does
not undermine the authoring result, but it must be fixed or precisely
documented before treating machteld's process supervision as robust.

## Stopping rule and useful next experiment

More repetitions of the same bounded functions would mostly reproduce the
ceiling. We now know the practically useful answer: with a specification and
compact language reference, current agents can write correct machteld/Tcl about
as reliably and with as little visible repair as Python across core algorithms,
a substantial stateful parser, and one process-control task. The recurring
cost is moderately larger ordinary Tcl source.

To distinguish the systems further, the next experiment should change the
question rather than inflate this sample: use blind bug-fix tasks in comparable
existing Tcl and Python repositories, with documentation lookup and token/tool
usage instrumented. A second high-value track is machteld-specific integration
(`store`, files, `child`/PTY, and deployment) after repairing the process
deadline hole.

## Evidence

- Serious panel: `experiment/serious/results/REPORT.md`
- Stateful supplement: `experiment/kvstore_probe/results/REPORT.md`
- Process probe: `experiment/run_probe/results/REPORT.md`
- Micro-pilot: `experiment/results/REPORT.md`

Each result directory contains machine-readable rows and summaries plus its
frozen manifest, exact submissions, attempt snapshots, apparatus, and runtimes.
The stateful supplement's closed bundle manifest SHA-256 is
`9623c80c7977e45c1670d0621ca0fc77c442809a4c6d1a2e20fcf696e186c4d9`.
