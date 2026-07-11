# Serious blind-trial runbook

This runbook is operational. The scientific choices are frozen in
`EXPERIMENT.md`; the common subject treatment is frozen in
`SUBJECT_PROTOCOL.md`. Do not improvise around either file after a subject has
started.

## 1. Preflight and freeze

1. Record the `_machteld` repository revision and all pre-existing unrelated
   worktree changes. Do not fold unrelated edits into the experiment or clean
   them destructively.
2. Read the preregistration, subject protocol, and corpus provenance.
3. Verify the generated corpus without writing it:

   ```powershell
   C:\dev\z.exe python -I -S -B experiment/serious/import_corpus.py --check
   ```

   It must report exactly 30 tasks, 90 visible cases, 464 hidden rows (17
   visible overlaps, 2 repeated hidden rows, 445 novel unique hidden rows),
   family counts 12/7/7/4, and difficulty counts 4/18/8.
4. Select the machteld runtime before setup. By default setup uses
   `experiment/serious/runtime/machteld.exe` when present, otherwise
   `experiment/run_probe/runtime/machteld.exe`. If `--machteld PATH` is used,
   record the reason and source hash before generation.
5. Exercise the apparatus and validate both references for every visible and
   hidden case:

   ```powershell
   C:\dev\z.exe python -I -S -B experiment/serious/bin/selftest.py
   C:\dev\z.exe python -I -S -B experiment/serious/bin/verify_refs.py
   ```

   A reference mismatch, wrong count, timeout, protocol error, or runtime-lock
   error is an infrastructure failure. Resolve it before assigning any subject.
6. Review the final `git diff` and run `git diff --check`. Freeze or commit the
   apparatus. Once the first subject starts, use only the importer's `--check`
   mode; do not regenerate tasks, primers, references, or infrastructure.

## 2. Generate the full matrix once

Run setup from `C:\dev\_machteld` with the preregistered seed:

```powershell
C:\dev\z.exe python -I -S -B experiment/serious/bin/setup_runs.py --seed 20260711
```

Setup must generate 180 shuffled cells and `runs/manifest.json`, copy and hash
the isolated runtimes under `runs/_frozen`, hash the complete apparatus and
every public cell artifact, and leave each solution file empty.

Preserve `runs/manifest.json`; never give it to a subject. Confirm before the
first assignment that:

- every task/arm pair has trials 1, 2, and 3 exactly once;
- there are 90 cells per arm and 180 total;
- manifest order is not an all-one-arm block;
- task, family, difficulty, primer, runtime, wrapper, and public-file hashes are
  present;
- `attempts/`, `results/`, and `subject-metadata.jsonl` contain no prior trial
  data.

`--force` may replace only generated state that setup proves pristine. There is
no authorized option to discard a nonempty submission, attempt, metadata row,
or result. If setup refuses, inspect and preserve the evidence rather than
working around the guard.

## 3. Isolation and blindness

A normal generated cell contains public material only, but its location below
the unrestricted shared workspace does not enforce blindness. Prefer an
external OS sandbox that exposes only:

- the assigned cell;
- its arm's manifest-pinned frozen runtime;
- the shared public checker required by `check.cmd`;
- the supervisor-owned write location for that cell's attempt records.

Deny access to `corpus/`, `refs/`, `_tika`, historical run directories,
manifests, results, sibling cells, and every other workspace project. A cell
copied without the checker/runtime/attempt path expected by its wrapper may not
be runnable, so test the staging recipe before a real assignment.

If enforced isolation is unavailable, explicitly label the study procedurally
blind. Give the subject the fixed prohibition against leaving its cell and
record any suspected oracle access as contamination.

## 4. Assign subjects

- Follow the 180 opaque cell IDs in `runs/manifest.json` order exactly. Do not
  choose tasks based on difficulty, arm, or earlier results.
- Run no more than three cells concurrently.
- Spawn one fresh no-context agent per cell with `fork_turns="none"`; never
  reuse an agent.
- Send only the exact `AGENT_PROMPT.md` text with
  `{{ABSOLUTE_CELL_PATH}}` replaced by the cell's absolute path.
- Do not answer language or algorithm questions, relay another outcome, or
  offer a post-result repair turn.
- End the cell under the stopping rule in `SUBJECT_PROTOCOL.md` and preserve
  the final solution exactly.
- Run all 180 planned cells. Do not inspect an interim aggregate, stop for a
  ceiling, or add trials for a surprising result.

Use the recorder instead of editing `subject-metadata.jsonl` manually. Before
assignment, create the unique row (wave and UTC start are derived safely):

```powershell
C:\dev\z.exe python -I -S -B experiment/serious/bin/record_subject.py start `
  --cell CELL --agent-id AGENT_ID --model-family GPT-5
```

After preserving the final solution, finish it. A normal completion is:

```powershell
C:\dev\z.exe python -I -S -B experiment/serious/bin/record_subject.py finish `
  --cell CELL --status completed --valid true
```

For the subject wall limit, use the same completed/valid status with
`--note wall_limit_reached`. For an invalid infrastructure or contamination
event, choose the matching non-completed status, pass `--valid false`, and
supply `--exclusion REASON`. The `complete` subcommand is an atomic one-shot
alternative when explicit start/end metadata are already known. Periodically
check the file with:

```powershell
C:\dev\z.exe python -I -S -B experiment/serious/bin/record_subject.py validate
```

The recorder enforces one row per opaque manifest cell, the manifest wave,
unique cell IDs, valid timestamps, and valid/status consistency. Grade also
requires a unique `agent_id` for each of all 180 rows. Do not infer an unexposed
model build or reasoning label.

Official `check.cmd` calls create supervisor-owned snapshots under the opaque
cell attempt directory and append `attempts.jsonl`. Do not edit, synthesize,
delete, or renumber these files. Manual commands do not count as official check
iterations.

## 5. Abnormal cells

- Incorrect code, candidate runtime error, candidate per-case watchdog timeout,
  or no visible green is an ordinary valid solver outcome.
- On the 10-minute subject wall limit, preserve the final code and record
  `status:"completed"`, `valid:true`, and note `wall_limit_reached`. Reserve
  metadata status `timed_out` for abnormal orchestrator termination, which is
  invalid.
- Broken frozen runtime, checker failure, wrong public treatment, accidental
  oracle access, or corrupted metadata is an infrastructure/validity event.
- Record the event before inspecting hidden correctness.
- Never replace a cell. Metadata must contain exactly one unique row for every
  manifest cell, including invalid cells.
- If the final matrix lacks three valid, completed subjects for any task-arm,
  withhold the primary classification and report the incomplete design.

## 6. Freeze, grade, and analyze

After all assignments end:

1. Make a read-only archival copy of `runs/manifest.json`, final solutions,
   attempt records, and `subject-metadata.jsonl` before hidden grading.
2. Grade final candidates:

   ```powershell
   C:\dev\z.exe python -I -S -B experiment/serious/bin/grade_runs.py `
     --manifest experiment/serious/runs/manifest.json `
     --metadata experiment/serious/subject-metadata.jsonl
   ```

   Grading must verify runtime, apparatus, public-file, metadata, attempt, and
   solution hashes before applying hidden cases. Infrastructure failures are
   reported separately from solver failures.
3. Run the preregistered deterministic analysis:

   ```powershell
   C:\dev\z.exe python -I -S -B experiment/serious/bin/analysis.py `
     --rows experiment/serious/results/rows.json
   ```

   Confirm the output records 200,000 Jeffreys-posterior draws with seed
   20260711, the task-weighted Δ and ±0.10 classification, plus the 200,000
   within-family paired-task bootstrap replicates with seed 20260712.
4. Publish per-cell and per-task rows, not only the headline classification.
   Report all exclusions, protocol deviations, infrastructure errors, family
   and difficulty summaries, and authoring metrics.
5. Write the narrative report without changing the analysis rule. Then seal
   and verify the closed bundle:

   ```powershell
   C:\dev\z.exe python -I -S -B experiment/serious/bin/bundle.py write
   C:\dev\z.exe python -I -S -B experiment/serious/bin/bundle.py verify
   ```

   Record the printed bundle-manifest SHA-256 with the report.

## 7. Afterward

Inspect failure modes only after the frozen primary output exists. Any revised
description, case, primer, runtime, checker, subject protocol, or statistical
rule starts a new experiment ID. Do not tune this apparatus and pool a rerun
with serious-v1.
