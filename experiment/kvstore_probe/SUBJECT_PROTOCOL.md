# Subject protocol: kvstore probe v1

**Frozen:** 2026-07-11, before any of the six subject trials.

## Common subject runtime

- Surface: a Codex subagent spawned from the primary Codex task.
- Model family: GPT-5, as identified by the active Codex configuration.
- Exact deployment/build identifier: not exposed; record it as unknown.
- Reasoning setting and token budget: the same inherited product defaults for
  every subject; internal values are not exposed.
- Limit: one independent solver turn and at most 10 minutes wall time.
- No coaching, task-specific follow-up, or replacement trial.

If the model family, exposed settings, tool surface, filesystem permissions,
prompt, primer, checker, or time limit changes before assignment, regenerate
all cells rather than mixing treatments.

## Context and blindness

- Spawn each subject with `fork_turns="none"`.
- One fresh agent handles exactly one cell and is never reused.
- Give every subject the exact envelope in `AGENT_PROMPT.md`, substituting only
  its absolute cell path.
- The cell contains only public task text/cases, its arm's primer, an empty
  solution, instructions, and the public check wrapper.
- The prompt forbids inspecting parents, siblings, infrastructure, corpus,
  hidden cases, references, previous solutions/results, the internet, or other
  agents. Do not answer language questions during a trial.
- Blindness is procedural on this shared Windows account, not an access-control
  boundary. Record any oracle access as contamination.

## Assignment and stopping

Follow the manifest's two balanced mixed-arm waves in order. Up to three cells
in a wave may run concurrently. Record external metadata for each assignment:
cell, wave, agent id, model family, UTC start/end, completion status, validity,
and any exclusion reason.

The subject edits only the named solution and may run `check.cmd` up to eight
times. Stop when the visible check passes and the subject declares completion,
the subject leaves its best attempt, or the common limit is reached. Preserve
the final file and every supervisor-owned attempt snapshot unchanged.

Run all six preassigned cells without examining interim grades. Do not grade
hidden cases until all final solutions and metadata are frozen.

## Fixed prompt envelope

```text
Your assigned cell is: {{ABSOLUTE_CELL_PATH}}

Read and follow `instructions.md` inside that directory. Work only inside that
cell. Do not inspect its parent, sibling cells, experiment infrastructure,
corpus, hidden cases, references, previous solutions, prior experiment results,
or the internet. Do not delegate.

Complete the task in the named solution file, use `check.cmd` for visible
feedback, and stop when it passes or when you have finished your best attempt.
```
