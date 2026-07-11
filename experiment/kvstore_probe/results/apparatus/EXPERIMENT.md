# Preregistered supplementary kvstore probe

**Frozen before subject assignment:** 2026-07-11.

## Purpose

This is a prospectively frozen descriptive supplement to the 30-task serious
algorithm panel. It asks whether the relative blind-agent difficulty changes
on one longer, stateful scripting problem: strict command parsing, mutable
key/value state, counts, nested transactions, rollback, commit, and fallible
input validation.

The complete existing Luax `kvstore` corpus is reused because it already has a
carefully specified behavior, three public examples, 59 hidden cases, signed
64-bit and whitespace edge cases, and an earlier differential-fuzzing history.
There is no task selection within that corpus and no case is changed.

## Design

- Task: `kvstore`, exactly one task.
- Arms: machteld 0.2.1 / Tcl 9.0.3 and Python 3.
- Replication: three fresh subjects per arm, six subjects total.
- Each subject sees the same neutral task text, the same three visible cases,
  and a matched language primer.
- Every planned cell is run. There is no interim look, early stop, adaptive
  sample size, or replacement after seeing performance.
- The manifest deterministically assigns the six cells in two adjacent waves
  of three, using complementary `MMP` and `PPM` arm patterns (or their reverse)
  so arm order is balanced across the pair.
- A fresh no-context agent solves exactly one cell. No agent is reused.
- A subject may invoke at most eight official visible checks. Every check
  snapshots its exact solution and runs each visible case in a fresh process.

## Outcomes fixed in advance

The primary outcome is binary per subject: the final submitted solution passes
all 59 hidden cases. Arm results are reported as raw `x/3` solve counts and all
six rows.

Secondary descriptive outcomes are:

1. number of official visible-check invocations (maximum eight);
2. whether the first official check passed all visible cases;
3. final UTF-8 source bytes;
4. final nonblank physical source lines;
5. final hidden cases passed out of 59, including the 25 expected-failure
   cases as ordinary exact cases.

Attempt snapshots may be graded on hidden cases after all trials are complete
to describe repair paths. That post-run diagnostic cannot replace the final
submission as the primary outcome.

No token measure is preregistered because the product does not expose a stable
per-subject token counter to this apparatus. Wall-clock observations, if
available, are operational metadata rather than a language-only outcome.

## Interpretation rule

This task is one fixed, deliberately demanding scripting anchor. With one task
and three stochastic repetitions per arm, the result cannot establish
equivalence, non-inferiority, or a population-wide language effect. Do not
compute or present an equivalence classification from this probe. Use it to
answer a narrower question: did either arm repeatedly fail this representative
stateful task, and where did the observed friction occur?

Report exact rows, solve counts, check counts, size measures, hidden failure
dimensions, and representative repair histories. Interpret it beside, not
pooled indiscriminately into, the multi-task serious panel.

## Corpus and treatment invariants

- `visible` and `hidden` are copied as JSON values from
  `_luax/experiment/tasks/kvstore.json` without selection, reordering, or
  changed expected results.
- Only the two-sentence block describing Luax/Python error syntax and the
  `FAIL` marker is rewritten into behaviorally identical, language-neutral
  wording.
- The source Python reference is extracted unchanged. The machteld reference
  is independently authored in core Tcl and must pass all 62 cases.
- Subjects never see hidden cases, references, provenance, sibling cells,
  previous experiment results, or the original Luax task.
- Primers cover corresponding mechanisms: lists, mappings, exact ASCII-space
  splitting, regular expressions, raised errors, strings, arbitrary-precision
  integers, and explicit 64-bit range checks.
- Runtime files, apparatus, public cell files, corpus, and references are
  hash-locked before the first assignment and must not change between cells.

## Validity and exclusions

A valid subject is a fresh assigned agent that receives the frozen prompt and
treatment, stays procedurally blind, and leaves a final solution or an explicit
best attempt within the common limit.

Record an infrastructure error separately if a locked runtime/checker fails,
the official check cannot execute, or required files are missing. Record
contamination and exclude the subject from arm denominators if it accesses a
hidden case, reference, prior solution/result, sibling cell, internet source,
or outside assistance. Record abnormal termination explicitly. Never silently
convert these states into solver failures or add a replacement after observing
the outcome.

The filesystem restriction is procedural: the shared Windows account can
technically read the larger workspace. The report must not call it enforced
sandbox isolation.

## Known limitations

- The hidden set contains 59 unique rows, but three rows also occur in the
  visible set. Report this inherited overlap; do not remove it post hoc.
- Twenty-five hidden rows expect an error. The corpus is therefore especially
  informative about exact parsing and failure behavior.
- Prior Luax/Python use makes the task externally motivated but not novel.
  Fresh machteld/Python subjects remain blind to that history.
- The result concerns this stateful, in-memory command processor. It does not
  cover filesystem, networking, concurrency, packaging, GUI, or process APIs.
