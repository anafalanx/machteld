# Subject protocol: run_probe v1

**Frozen:** 2026-07-11, before any subject trial.

This file fixes the treatment shared by all six cells. Product internals that
Codex does not expose are recorded as unknown rather than guessed.

## Subject runtime

- Surface: Codex subagent spawned from the primary Codex task.
- Model family: GPT-5, as identified by the active Codex system configuration.
- Exact deployment or build identifier: not exposed by the product.
- Reasoning setting: the same inherited product default for every subject; its
  internal label is not exposed.
- Explicit token budget: none exposed or supplied; each subject receives the
  same product default.
- Maximum wall time: 10 minutes per subject.
- Turns: one independent solver turn, with no coaching or task-specific
  follow-up.

If any of these conditions changes before assignment, update this protocol and
regenerate every cell before running a subject. Never mix treatments under one
result table.

## Context and tools

- Spawn every subject with `fork_turns="none"`; it inherits no portfolio,
  experiment-design, or prior-trial conversation.
- One fresh agent handles exactly one cell and is never reused in either arm.
- Every subject receives the same Codex tool surface and filesystem
  permissions.
- The fixed prompt forbids reading outside the assigned cell, using the web,
  delegating, or inspecting hidden corpus, fixture internals, references, or
  prior results.
- Blindness is procedural because this Windows account can technically read
  the wider `C:\dev` tree. The experiment does not describe that as enforced
  isolation.

## Assignment and stopping

- Follow the deterministically shuffled order in `runs/manifest.json`; do not
  run all of one arm first.
- At most three cells may run concurrently. Record wave membership and status
  in `subject-metadata.jsonl`, including an explicit `valid` flag and exclusion
  reason. Grading refuses missing/duplicate metadata and excludes invalid or
  contaminated subjects from the solve-rate denominator.
- Give the subject only the exact prompt envelope below with its absolute cell
  path. The cell's `instructions.md`, `primer.md`, and `task.md` provide the
  remainder of the prompt.
- The subject may edit only its named solution and may invoke `check.cmd` for
  visible feedback.
- Stop when `check.cmd` passes and the subject declares completion, when the
  subject submits its best attempt, or at the common 10-minute limit.
- Do not answer language or API questions during a trial. The supplied primer
  is the arm's fixed reference.
- Record abnormal termination, accidental oracle access, or infrastructure
  failure. Do not silently turn one into a solver failure or replacement
  trial.

## Fixed prompt envelope

```text
Your assigned cell is: {{ABSOLUTE_CELL_PATH}}

Read and follow `instructions.md` inside that directory. Work only inside that
cell. Do not inspect its parent, sibling cells, the experiment infrastructure,
the hidden cases, references, fixture internals, previous solutions, or the
internet. Do not delegate.

Complete the task in the named solution file, use `check.cmd` for visible
feedback, and stop when it passes or when you have finished your best attempt.
```
