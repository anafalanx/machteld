# Blind-trial runbook

The repository contains hidden cases and reference solutions. A generated cell
contains only public material, but placing it below the same unrestricted
`C:\dev` tree does not prevent a solver from reading the oracle. Treat the
current layout as a convenient staging area.

## Before assigning cells

1. Run `C:\dev\z.exe python -B experiment/bin/verify_refs.py`.
2. Run `C:\dev\z.exe python -B experiment/bin/setup_runs.py` once.
3. Keep `runs/manifest.json` for the orchestrator; do not give it to solvers.
4. Record the exact agent model/version, settings, tool access, token budget,
   and wall-clock limit that every cell will receive.
5. For enforced isolation, stage a public tree preserving
   `experiment/runs/cell-NNN`, `experiment/bin/check.py`, and a
   supervisor-writable `experiment/attempts` directory. Allow read/execute only
   for the pinned Python distribution and machteld executable. Deny access to
   `corpus`, `refs`, `_luax`, `_tika`, the manifest, and every other cell. A
   copied cell by itself is not runnable because its wrapper intentionally calls
   the shared public checker.

If enforced filesystem isolation is unavailable, explicitly label the run
procedurally blind and instruct the agent not to inspect anything outside its
cell. Do not quietly describe that as sandboxed.

## Assigning a cell

- Follow manifest order, which is deterministically shuffled with the recorded
  seed; do not run all of one arm first.
- Use a fresh, no-context agent for exactly one cell (`fork_turns="none"` or
  the equivalent); never fork this design discussion into a solver.
- Send the text of `AGENT_PROMPT.md` and the cell path—nothing from the corpus,
  design discussion, or prior trials.
- Do not answer language questions during a trial. The supplied primer is the
  arm's allowed reference.
- Stop when the agent declares completion or reaches the common resource limit.
- Preserve its final solution and the supervisor-owned
  `attempts/cell-NNN.jsonl` unchanged.
- Record abnormal termination, infrastructure failure, or accidental oracle
  access rather than silently rerunning the same cell.

Suggested external metadata row:

```json
{"cell":"cell-001","model":"...","started_utc":"...","ended_utc":"...","input_tokens":null,"output_tokens":null,"status":"completed","note":""}
```

## Grading

After all assigned cells are frozen, run:

```powershell
C:\dev\z.exe python -B experiment/bin/grade_runs.py
```

The grader uses only final files for hidden correctness. Visible `check` calls
are already counted in supervisor-owned JSONL logs. It first verifies runtime,
apparatus, public-file, and reference hashes, then freezes the manifest,
submissions, attempts, and apparatus into `results/`. Publish the per-cell rows
as well as aggregates; with six trials per arm, individual failures matter more
than a single headline percentage.

Do not tune the primer or task wording after seeing a trial and then mix the
rerun with the original pilot. Any revised design starts a new experiment ID.
