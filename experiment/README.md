# machteld vs Python: agent pilot

This directory contains a deliberately small blind-agent comparison of
machteld/Tcl and Python. It derives two tasks from the existing Tika/Luax
corpus, preserving all original cases and adding four pre-trial lexical cases
to `sum_ints`:

- `gcd`: a one-shot arithmetic/control-flow calibration;
- `sum_ints`: tokenization and strict decimal parsing, which produced repair
  iterations in the earlier Luax study.

The pilot is an exploratory apparatus shakedown, not a test of the whole
machteld thesis.
It tests whether fresh agents can write small pure functions from a compact Tcl
primer. It does **not** yet exercise machteld's process supervision, SQLite,
Tk, wrapping, or single-executable deployment.

The design was frozen in [`EXPERIMENT.md`](EXPERIMENT.md) before any blind
machteld trial was run.

Use [`RUNBOOK.md`](RUNBOOK.md) when assigning the generated cells. In
particular, the ordinary shared `C:\dev` filesystem provides procedural, not
enforced, blindness.

The concrete model/context/tool/timeout treatment for this run is frozen in
[`SUBJECT_PROTOCOL.md`](SUBJECT_PROTOCOL.md).

## Quick start

From the machteld repository root:

```powershell
# Validate both arms' reference solutions on every visible and hidden case.
C:\dev\z.exe python -B experiment/bin/verify_refs.py

# Create 12 isolated run directories: 2 tasks x 2 arms x 3 trials.
C:\dev\z.exe python -B experiment/bin/setup_runs.py

# Give each directory to one fresh agent, using experiment/AGENT_PROMPT.md.
# After all agents finish, grade final files on hidden cases:
C:\dev\z.exe python -B experiment/bin/grade_runs.py
```

Set `MACHTELD_BIN` to test another executable. The default is the existing
signed `build/machteld.exe`. Generated `check.cmd` files pin the same Python
interpreter that ran `setup_runs.py`; setup and grading likewise use their own
interpreter.

Generated sandboxes live under `runs/`; aggregate JSON is written to
`results/`. Check records are supervisor-owned files under `attempts/`, not
files inside solver cells. All three generated areas are ignored by Git except
for their placeholder files.

`grade_runs.py` freezes the manifest, submitted sources, attempt logs, and a
copy of the hashed apparatus into the result bundle before reporting. Setup
will not discard nonempty submissions unless both `--force` and the explicit
`--discard-submissions` acknowledgement are supplied.
