# Stateful `kvstore` supplement: machteld/Tcl versus Python

**Run date:** 2026-07-11

**Frozen apparatus commit:** `f2c996f4d85c4e2d2d93215ed148e8b473a11b42`

**Run-manifest SHA-256:** `8efc2ff318a96b42c5e2037e98ac1868874df77143d0cd565bda2299d87db49a`

## Result

Blind GPT-5 coding agents found the reused stateful scripting task easy in
both arms. All three machteld/Tcl subjects and all three Python subjects passed
all 59 hidden cases. Every final submission was already hidden-correct at its
first and only official visible check.

| Arm | Hidden-correct | Hidden executions | One-check solves | Median bytes | Median nonblank lines |
|---|---:|---:|---:|---:|---:|
| machteld/Tcl | 3/3 | 177/177 | 3/3 | 4,810 | 148 |
| Python | 3/3 | 177/177 | 3/3 | 3,301 | 90 |

The task includes 25 expected-error hidden rows. Thus each arm passed 75/75
malformed-input executions as well as 102/102 normal-result executions. Three
hidden rows are inherited copies of visible examples; excluding those, both
arms still passed all 168 novel-to-visible executions.

This is a correctness and visible-iteration ceiling, not evidence that the
arms are exactly equal. The preregistration deliberately treats the task as a
descriptive supplement: one task with three repetitions per arm cannot support
an equivalence or superiority classifier.

## Exact subject rows

| Cell | Arm | Trial | Hidden | Checks | Bytes | Nonblank lines |
|---|---|---:|---:|---:|---:|---:|
| `cell-23b6dab7f27d75e1` | Python | 3 | 59/59 | 1 | 3,305 | 90 |
| `cell-8578d6769c3f4491` | Python | 1 | 59/59 | 1 | 2,556 | 68 |
| `cell-fccb7384fbd917c2` | machteld/Tcl | 2 | 59/59 | 1 | 4,810 | 148 |
| `cell-1eef67ab9408948b` | machteld/Tcl | 3 | 59/59 | 1 | 6,886 | 186 |
| `cell-bf004c39426d018e` | machteld/Tcl | 1 | 59/59 | 1 | 4,202 | 138 |
| `cell-faabd16dd6b240a0` | Python | 2 | 59/59 | 1 | 3,301 | 93 |

All six metadata rows are valid completions with unique fresh-agent IDs. There
were no exclusions, infrastructure failures, checker-cap violations, public
artifact changes, or detected protocol deviations. The product admitted two
concurrent subjects, so each three-cell wave ran as 2+1 while retaining the
frozen order and staying within the allowed maximum of three.

## Authoring behavior

The agents independently used reasonable transaction designs:

- one submission in each arm snapshotted the whole store at `BEGIN`;
- the other four used per-transaction undo maps/logs;
- all three Python submissions maintained value counts incrementally, while
  all three Tcl submissions counted by scanning current values;
- every submission implemented exact ASCII-space tokenization, strict command
  arity, signed-64-bit bounds, nested rollback, and all-open commit correctly.

The machteld median was 1.46 times the Python median in bytes and 1.64 times
the Python median in nonblank lines. Much of that observed difference is in
integer parsing and validation: Python agents could combine `re.fullmatch`
with `int`, while the Tcl agents chose explicit digit/range handling. One Tcl
submission also duplicated that parser in two command branches, producing the
largest row. The result is therefore a real authoring-footprint observation,
but not a controlled measure of language syntax alone.

## Corpus reuse and validation

The complete existing `_luax/experiment/tasks/kvstore.json` case set was
reused, not sampled:

- 3 visible and 59 hidden rows, in the original order;
- 59 unique hidden rows, including 25 expected failures;
- exact case-value SHA-256 values `decd9295a4ad1928e26519891710701111f7135a8380221c4727604adfa3c35a`
  (visible) and `318598ef10bf9ae72e536b5e8d65eba14171a114fbf3cda3b4fa090104316d45`
  (hidden);
- only the two-sentence Luax/Python error-signalling block was changed to
  behaviorally identical language-neutral wording.

Both references passed all 62 visible-plus-hidden rows through the actual
checker before assignment (124/124 arm/case executions). An independent audit
also exercised each reference on 250 seeded generated sequences covering
nested transactions, malformed input, integer boundaries, Unicode, NUL, tabs,
newlines, and Tcl-sensitive keys; all 500 executions passed. That stress run
was a pretrial audit rather than a preregistered subject endpoint.

The audit found and corrected two apparatus defects before assignment: copied
Python bytecode caches had not been covered by the inherited semantic lock,
and the original wave shuffles were not position-complementary. The final
setup copies only the 752 locked Python files and additionally hashes every
regular file without exclusions; both frozen tree hashes are
`4f834ca1eb4f7e0b631a7a041201467a13ee2975ece72f1359c00712cd94c1ff`.
The two final arm waves are exactly complementary (`PPM`, then `MMP`). No
subject had been assigned before those corrections and the final freeze.

## Interpretation

This closes the most important gap left by the 30-task serious panel. With a
matched compact primer and a precise specification, fresh agents can author
correct core-Tcl code for a substantial stateful, string-heavy, fallible
command processor on their first checked attempt. There is no observed
correctness or repair disadvantage relative to Python here; the observed cost
is larger source.

The claim remains bounded. This one task does not test files, sockets,
concurrency, SQLite, Tk, PTYs, packaging, deployment, or maintenance in an
existing Tcl codebase. Blindness was procedural because every subject shared
an unrestricted Windows account. The task and primers supplied unusually
precise behavior and relevant language mechanisms, so the experiment measures
documented authoring ability rather than unaided API recall.

## Reproducibility

`rows.json`, `attempt-rows.json`, and `summary.json` contain all outcomes and
source metrics. The result bundle also archives the exact apparatus, manifest,
metadata, six public cells and submissions, six official-check snapshots, and
both frozen runtimes. `bundle-manifest.json` hashes every bundled file except
itself after this report is finalized.
