# Blind-trial runbook

The repository contains hidden cases, reference solutions, and fixture source.
A generated cell omits them, but its location beneath the same unrestricted
`C:\dev` tree is not an access-control boundary. Treat this layout as
procedurally blind unless the cells are staged in a separate OS sandbox.

## Before assigning cells

1. Review `EXPERIMENT.md`, `SUBJECT_PROTOCOL.md`, and the case provenance.
2. Snapshot the machteld runtime, build the neutral fixture, and validate that
   every locked hash in `RUNTIME_LOCK.json` matches. Then run:

   ```powershell
   C:\dev\z.exe python -I -S -B experiment/run_probe/bin/selftest.py
   C:\dev\z.exe python -I -S -B experiment/run_probe/bin/verify_refs.py
   ```

   Both references must pass all three visible and six hidden cases, including
   the PID-backed timeout cleanup check.
3. Commit the now-built and verified frozen apparatus. Record the repository
   HEAD and existing unrelated worktree changes rather than silently folding
   them into the experiment.
4. Generate the six cells once:

   ```powershell
   C:\dev\z.exe python -I -S -B experiment/run_probe/bin/setup_runs.py
   ```

5. Preserve `runs/manifest.json` for the orchestrator. Never give it, the
   hidden case file, references, fixture source, or sibling cells to a subject.
6. Confirm that the manifest pins the exact Python interpreter, machteld
   executable, native fixture, apparatus, and every public cell file. Do not
   rebuild or replace any of them after setup.
7. Confirm that every subject will receive the treatment in
   `SUBJECT_PROTOCOL.md`. If the model, settings, permissions, or resource
   limits change, regenerate all cells before beginning.

For enforced blindness, stage only the generated cell, read-only fixture,
shared public checker, supervisor-writable attempt path, and pinned runtimes.
Deny access to `cases/`, `refs/`, fixture source, manifests, results, sibling
cells, and the earlier experiment.

## Assigning cells

- Follow manifest order, which is deterministically shuffled. Do not run all
  machteld cells or all Python cells first.
- Use one fresh no-context agent for one cell only (`fork_turns="none"`).
- Send the exact text of `AGENT_PROMPT.md` plus the cell's absolute path.
- Do not explain APIs, answer questions, or relay another subject's outcome.
- Stop on a passing visible check and declared completion, the subject's best
  final attempt, or the common 10-minute limit.
- Preserve the final solution and supervisor-owned attempt log unchanged.
- Append one external metadata row for each assigned cell, for example:

  ```json
  {"cell":"cell-001","wave":1,"agent_id":"...","model_family":"GPT-5","started_utc":"...","ended_utc":"...","status":"completed","valid":true,"exclusion":null,"note":""}
  ```

An infrastructure error, accidental oracle access, or abnormal termination is
recorded as such. Do not silently substitute a new subject after seeing the
cell's result.

## Grading

After all six final solutions and attempt logs are frozen, run:

```powershell
C:\dev\z.exe python -I -S -B experiment/run_probe/bin/grade_runs.py
```

The grader must verify all pinned hashes before running hidden cases. It stages
the manifest, submissions, attempts, subject metadata, exact runtime files,
and hashed apparatus in `results/`, then emits per-cell rows and descriptive
arm aggregates. Write `results/REPORT.md`, seal the completed bundle, and
verify it:

```powershell
C:\dev\z.exe python -I -S -B experiment/run_probe/bin/bundle.py write
C:\dev\z.exe python -I -S -B experiment/run_probe/bin/bundle.py verify
```

Record the printed SHA-256 of `bundle-manifest.json` with the final report.

Inspect any failure by dimension before interpreting it. Report infrastructure
failures separately. With only three trials per arm, individual rows matter
more than a headline rate.

Do not alter the task, primers, cases, checker semantics, or fixture and then
mix a rerun into this experiment. A revised design receives a new identifier
and a new pre-registration.
