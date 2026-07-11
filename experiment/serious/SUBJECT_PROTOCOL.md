# Subject protocol: serious-v1

**Frozen:** 2026-07-11, before any subject trial.

This file fixes the treatment shared by all 180 cells. Product details that are
not exposed are recorded as unknown rather than inferred.

## Subject runtime

- Surface: Codex subagent spawned from the primary Codex task.
- Model family: GPT-5, as identified by the active Codex system configuration.
- Exact deployment/build identifier: not exposed by the product.
- Reasoning setting: the same inherited product default for every subject; its
  internal label is not exposed.
- Explicit token budget: none exposed or supplied; every subject receives the
  same product default.
- Maximum wall time: **10 minutes per subject**.
- Turns: one independent solver turn, with no coaching or task-specific
  follow-up.

If model family, settings, token treatment, wall limit, tool surface, or
filesystem permissions change before assignment, stop and regenerate every
cell. Do not mix treatments in one result table.

## Independence, context, and tools

- Spawn each subject with `fork_turns="none"`; no design discussion, earlier
  trial, portfolio analysis, or prior solution context is inherited.
- One fresh subject handles exactly one task/arm/trial cell and is never reused.
- Every subject inherits the same Codex tool surface and filesystem permissions.
- The subject may edit only the named solution file in its assigned cell.
- The fixed prompt forbids reading outside the cell, web access, delegation,
  hidden-corpus inspection, reference inspection, and prior-result inspection.
- Do not install packages or provide task-specific information during a trial.
- Blindness is procedural unless the cell is staged behind an external OS
  access-control boundary. The shared Windows account can technically read the
  wider `C:\dev` tree.

## Assignment order and concurrency

- Generate the complete matrix with setup seed `20260711`.
- Follow `runs/manifest.json` order exactly across its 180 opaque cell IDs.
- Run at most three cells concurrently and record wave membership.
- Do not run all of one arm together or choose the next cell based on outcomes.
- Run every planned cell. No interim result is used to stop, extend, reorder, or
  otherwise modify the study.

## Fixed prompt envelope

The orchestrator sends only this text, with the assigned absolute path filled
in:

```text
Your assigned cell is: {{ABSOLUTE_CELL_PATH}}

Read and follow `instructions.md` inside that directory. Work only inside that
cell. Do not inspect its parent, sibling cells, experiment infrastructure,
corpus, hidden cases, references, previous solutions, prior experiment results,
or the internet. Do not delegate.

Complete the task in the named solution file, use `check.cmd` for visible
feedback, and stop when it passes or when you have finished your best attempt.
```

The cell's hash-pinned `instructions.md`, `primer.md`, `task.md`, and
`visible.json` constitute the remainder of the subject prompt.

## Stopping a cell

A cell ends at the first of:

1. `check.cmd` passes and the subject declares completion;
2. the subject declares its best final attempt without a visible pass;
3. the common 10-minute wall limit expires, at which point the final code is
   preserved as a completed best attempt;
4. the orchestrator identifies an infrastructure or contamination event.

Do not answer a language, algorithm, or API question during a trial. Do not
offer an extra repair turn after seeing the subject's result. Preserve the final
solution exactly as left.

## Metadata and validity

Create and finish one external JSONL record per assigned cell in
`subject-metadata.jsonl` through `bin/record_subject.py`; do not edit the file
manually. Record cell, manifest wave, unique agent identifier, model family,
start/end UTC, terminal status, validity, and an exclusion reason when invalid.
Example row:

```json
{"cell":"cell-0123456789abcdef","wave":1,"agent_id":"...","model_family":"GPT-5","started_utc":"...","ended_utc":"...","status":"completed","valid":true,"exclusion":null,"note":""}
```

Ordinary incorrect code, a candidate per-case watchdog timeout, or failure to
obtain a visible green is a valid trial. A subject that reaches the 10-minute
wall limit is recorded with status `completed`, `valid:true`, and note
`wall_limit_reached`; its preserved final code is its best attempt. Metadata
status `timed_out` is reserved for abnormal orchestrator termination and is
invalid. Infrastructure failure, wrong treatment, or oracle access is likewise
marked invalid. There are no replacements: metadata contains exactly one unique
row for each of the 180 opaque manifest cells, and every invalid record is
retained. The primary classification is withheld if the valid completed matrix
is not full.

Official visible checks create supervisor-owned attempt snapshots outside the
cell. Do not edit, synthesize, delete, or renumber them. The grader verifies the
manifest, public-file hashes, runtime locks, attempts, metadata, and final
candidate before hidden grading.
