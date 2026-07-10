# Subject protocol v1

**Frozen:** 2026-07-11, before any subject trial.

This file fixes the treatment shared by all 12 cells in the machteld/Tcl versus
Python micro-pilot. Product internals that Codex does not expose are recorded
as such rather than guessed.

## Subject runtime

- Surface: Codex subagent spawned from the primary Codex task.
- Model family: GPT-5, as identified by the active Codex system configuration.
- Exact deployment/build identifier: not exposed by the product.
- Reasoning setting: the same inherited product default for every subagent;
  its internal label is not exposed.
- Explicit token budget: none exposed or supplied; every subject receives the
  same product default.
- Maximum wall time: 10 minutes per subject.
- Turns: one independent solver turn; no coaching or task-specific follow-up.

## Context and tools

- Spawn with `fork_turns="none"`; no conversation or portfolio-analysis context
  is inherited.
- One fresh subagent handles exactly one cell and is never reused in either arm.
- All subjects inherit the same Codex tool surface and filesystem permissions.
- The fixed prompt forbids reading outside the assigned cell, using the web,
  delegating to another agent, or inspecting corpus/oracle/prior-run material.
- Blindness is procedural because this Windows account can technically read the
  wider `C:\dev` tree. The user explicitly accepted this limitation.

## Assignment and stopping

- Follow the already shuffled manifest order `cell-001` through `cell-012`.
- Up to three cells may execute concurrently; wave membership and completion
  status are recorded in `subject-metadata.jsonl`.
- Give the subject only the exact text of `AGENT_PROMPT.md` plus its absolute
  cell path.
- The subject stops after the provided visible check passes, when it declares
  completion, or at the common 10-minute wall limit.
- Infrastructure failures are recorded and not silently converted into solver
  failures. Subjects receive no language help during a trial.

## Fixed prompt envelope

```text
Your assigned cell is: <ABSOLUTE_CELL_PATH>

Read and follow instructions.md inside that directory. Work only inside that
cell. Do not inspect its parent, sibling cells, the experiment infrastructure,
the corpus, references, previous solutions, or the internet. Do not delegate.
Complete the task in the named solution file, use check.cmd for visible
feedback, and stop when it passes or when you have finished your best attempt.
```

The cell's `instructions.md`, `primer.md`, and `task.md` are hash-pinned by the
manifest and constitute the remainder of the subject prompt.
