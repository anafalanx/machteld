# run_probe: machteld versus Python

This is the first follow-on to the small pure-function agent pilot. It compares
one concrete machteld capability against Python's documented standard-library
path: launching a native process without a shell, capturing both streams,
normalizing its exit, and cleaning up a timeout.

The experiment is deliberately small:

- one fixed task;
- two arms, machteld/Tcl and Python;
- three fresh-agent trials per arm;
- three visible and six hidden cases.

It reuses the earlier pilot's blind-cell, attempt-log, hash-pinning, and hidden
grading approach. The process vectors are adapted from machteld's existing
`test/run_test.tcl` and `test/cmdline_test.c`; see
`cases/PROVENANCE.md` for the boundary between reused and new cases.

The question, metrics, confounds, and ceiling interpretation are frozen in
`EXPERIMENT.md`. The common agent treatment is frozen in
`SUBJECT_PROTOCOL.md`. Read `RUNBOOK.md` before assigning a cell.

## Layout

```text
cases/       registered visible and hidden cases, plus provenance
primers/     arm-specific factual references copied into cells
refs/        oracle implementations; never copied into cells
fixture/     native process fixture and source
runtime/     frozen machteld executable and runtime lock provenance
bin/         setup, checking, reference verification, and grading
runs/        generated blind cells (Git-ignored)
attempts/    supervisor-owned visible-check logs (Git-ignored)
results/     frozen result bundles (Git-ignored)
```

The shared `C:\dev` tree provides procedural, not enforced, blindness.

## Quick start

From `C:\dev\_machteld`:

```powershell
# Exercise checker rejection/cleanup paths, then validate both references.
C:\dev\z.exe python -I -S -B experiment/run_probe/bin/selftest.py
C:\dev\z.exe python -I -S -B experiment/run_probe/bin/verify_refs.py

# Generate six shuffled cells: one task x two arms x three trials.
C:\dev\z.exe python -I -S -B experiment/run_probe/bin/setup_runs.py

# Assign each cell to one fresh no-context subject using AGENT_PROMPT.md.
# After all submissions are frozen, apply hidden grading:
C:\dev\z.exe python -I -S -B experiment/run_probe/bin/grade_runs.py

# After writing results/REPORT.md, seal and verify the closed bundle.
C:\dev\z.exe python -I -S -B experiment/run_probe/bin/bundle.py write
C:\dev\z.exe python -I -S -B experiment/run_probe/bin/bundle.py verify
```

The checker interface is intentionally shared by visible and hidden grading:

```text
check.py --arm machteld|python --solution PATH --cases PATH --fixture PATH
```

Setup enforces `RUNTIME_LOCK.json` and pins the Python runtime tree, machteld
executable, native fixture, public
cell files, and experiment apparatus in `runs/manifest.json`. Do not rebuild or
replace a pinned runtime or fixture between setup and grading.

Generated cells and results are ignored by Git except for placeholder files.
Setup must refuse to discard nonempty submissions or attempt logs without an
explicit destructive acknowledgement.
