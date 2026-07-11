# kvstore probe runbook

The source tree contains hidden cases and references. Generated cells omit
them, but their location under the same unrestricted workspace provides only
procedural blindness. Use a separate OS sandbox if enforced isolation is
required.

## Freeze and verify

1. Read `EXPERIMENT.md`, `SUBJECT_PROTOCOL.md`, and
   `corpus/provenance.json`.
2. Regenerate the deterministic import and verify that the working tree shows
   no unexpected corpus/reference drift:

   ```powershell
   C:\dev\z.exe python -I -S -B experiment/kvstore_probe/import_corpus.py
   ```

3. Run the apparatus self-test and reference verification commands supplied in
   `bin/`. Both Python and machteld references must pass all 62 cases, including
   all 25 hidden `FAIL` expectations.
4. Review the matched primers and public task rendering. Ensure neither arm
   receives an implementation or oracle unavailable to the other.
5. Commit the frozen apparatus while preserving unrelated user changes.
6. Generate all six cells once with the setup command in `bin/`. Confirm that
   its sealed manifest pins runtimes, apparatus, public files, task assignment,
   two complementary mixed-arm waves, and the maximum of eight checks.
7. Do not change any pinned file after the first assignment.

## Assign all six cells

- Follow manifest order and wave membership exactly.
- Spawn one fresh agent per cell with no inherited turns.
- Send only the exact `AGENT_PROMPT.md` envelope plus the absolute cell path.
- Never expose corpus files, hidden cases, references, sibling cells, or prior
  outcomes; do not coach a running subject.
- Preserve every official-check snapshot and the final solution.
- Record one metadata row per cell, including validity and exclusion reason.
- Run every preassigned subject, even if the first wave looks decisive.
- Do not inspect hidden performance until all six trials are complete.

Example metadata shape (the apparatus command is authoritative):

```json
{"cell":"cell-001","wave":1,"agent_id":"...","model_family":"GPT-5","started_utc":"...","ended_utc":"...","status":"completed","valid":true,"exclusion":null,"note":""}
```

## Grade and report

After freezing all six final files and metadata, run the grader in `bin/`. It
must verify all manifest/runtime/apparatus hashes before executing hidden cases
and must distinguish solver failures from infrastructure errors and exclusions.

The report must include:

- all six subject rows;
- arm solve counts out of three;
- official check counts and first-check success;
- source bytes and nonblank lines;
- hidden pass counts out of 59 and failures by behavioral dimension if the
  corpus supplies dimensions;
- any contamination, exclusion, or infrastructure error;
- selected attempt-path diagnostics only after final grading;
- the inherited three-case visible/hidden overlap and n=1 limitation;
- an explicit statement that no equivalence claim is supported.

Stage the exact runtimes, apparatus, manifest, metadata, submissions, attempts,
and grades into `results/`, write `results/REPORT.md`, then write and verify the
bundle manifest using the commands supplied in `bin/`. Record its SHA-256 in
the final handoff.
