# kvstore blind-agent probe

This directory is a prospectively frozen supplementary comparison of blind
agent-written machteld/Tcl and Python on one stateful scripting task. It reuses
the full validated `kvstore` task from the earlier Luax experiment: three
visible cases and 59 hidden cases, with no case selection or behavioral edits.

The design is `1 task × 2 arms × 3 fresh trials = 6 subjects`. The primary
outcome is whether each final solution passes all 59 hidden cases. Check count,
first-visible-check success, source bytes/lines, and hidden case fraction are
descriptive secondaries. Because the task-level sample size is one, this probe
makes no equivalence or general language claim.

## Layout

- `corpus/kvstore.json` — neutral task and the complete frozen cases.
- `corpus/provenance.json` — authoritative source, case, and generated hashes.
- `refs/` — independently checked gold solutions; never exposed to subjects.
- `primers/` — matched public language references.
- `bin/` — setup, checking, grading, and sealing apparatus.
- `runs/` — generated public cells and sealed manifest.
- `attempts/` — supervisor-owned snapshots from official visible checks.
- `results/` — staged final submissions, grades, apparatus, and report.

Read `EXPERIMENT.md` for the preregistration, `SUBJECT_PROTOCOL.md` for the
fixed treatment, and `RUNBOOK.md` before assigning any subject.

Regenerate the imported corpus deterministically with:

```powershell
C:\dev\z.exe python -I -S -B experiment/kvstore_probe/import_corpus.py
```

The importer asserts the 3/59 counts, the 25 hidden expected failures, exact
case-value equality, and unchanged extraction of the source Python reference.
