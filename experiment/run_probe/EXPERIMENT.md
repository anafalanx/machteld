# Pre-registration: machteld `run` versus Python `subprocess.run`

**Frozen:** 2026-07-11, before any `run_probe` subject trial.

## Question

Can a fresh coding agent, given a compact factual primer, implement a small
direct-process wrapper with comparable correctness and repair counts using
machteld/Tcl or ordinary Python?

This experiment tests one narrow claim: whether machteld's structured `run`
primitive makes a common piece of Windows process control compact and legible
to an agent. It is not a general comparison of Tcl and Python.

## Task and arms

Every subject implements the same function:

```text
run_probe(helper, mode, payload) -> [status, exit, out, err]
```

The function directly launches a hash-pinned native helper with exactly two
arguments, applies a fixed 200 ms timeout, captures UTF-8 stdout and stderr,
normalizes completed status and exit code, and ensures the directly launched
helper is dead before returning from a timeout.

- **machteld arm:** `solution.tcl`, loaded by the pinned machteld executable;
  the primer documents `run -timeout 200ms -- ...` and its result dictionary.
- **Python arm:** `solution.py`, imported by the pinned Python interpreter; the
  primer documents `subprocess.run`, text capture, and `TimeoutExpired`.

Both primers are part of their treatment. Each documents the relevant API but
does not contain a complete `run_probe` implementation.

## Native oracle

The native fixture is invoked as:

```text
process_fixture.exe MODE PAYLOAD
```

Its behavior is fixed:

| Mode | Exit | stdout | stderr |
|---|---:|---|---|
| `ok` | 0 | exactly `PAYLOAD` | exactly `E:PAYLOAD` |
| `fail` | 7 | exactly `PAYLOAD` | exactly `E:PAYLOAD` |
| `hang` | does not complete | empty | empty |

There are no trailing newlines. The fixture uses a Unicode `wmain` entry point,
converts explicitly to UTF-8, and writes with Win32 APIs, avoiding console-code
page and shell behavior.

In every mode it writes its PID to the path supplied through the inherited
`MACHTELD_PROBE_PIDFILE` environment variable and closes that file. This lets
the checker require at least one real helper launch in every case. In `hang` mode it
then sleeps for five seconds. The checker also uses the PID to verify that the
direct child is gone after `run_probe` returns. The candidate need not know
about or manipulate the PID file.

## Cases

The corpus contains exactly three visible and six hidden cases.

The visible set demonstrates all three modes:

- `ok` with `hello world`;
- `fail` with `a"b\c & d`;
- `hang` with `ignored`.

The hidden set covers an empty payload, non-ASCII UTF-8, shell-looking
characters, a 4096-byte payload, an awkward Unicode/quoting payload, and a
second hang. Payloads are strings without NUL characters. Output remains well
below machteld's capture limit.

The cases and their provenance are fixed in `cases/` before any subject is
assigned. Reference solutions are used only to validate the apparatus and are
never copied into a subject cell.

## Trials and blindness

- One task, two arms, three independent trials per arm: **six trials total**.
- One fresh agent per trial. No agent handles another cell or both arms.
- Cells are deterministically shuffled so an arm is not run as one block.
- Subjects receive only their generated cell and the fixed prompt envelope in
  `AGENT_PROMPT.md`.
- A cell contains the task, its arm primer, visible cases, an empty solution,
  the read-only fixture, and a check wrapper. It contains no hidden cases,
  references, prior solutions, or result summaries.
- The shared `C:\dev` filesystem is not a security boundary. Unless an
  external sandbox is supplied, blindness is explicitly **procedural**.

Public cell files and the fixture are read-only and hash-pinned in the run
manifest. Visible-check attempts are written outside the cell to a
supervisor-owned JSONL log.

## Checking and grading

Each case executes the candidate in a fresh native-runtime process. The public
checker reports the first visible mismatch with native Tcl or Python
diagnostics. Hidden grading uses the same checker contract after submissions
are frozen.

For `hang`, the checker requires all of the following:

- status `timeout`, exit `-1`, and two empty streams;
- return well before the fixture's five-second sleep completes;
- the PID published by the fixture no longer denotes a live direct child.

Failure to launch the helper at all is not accepted as successful cleanup.
Fixture startup or PID-publication failures are infrastructure errors rather
than silently reclassified solver failures.

## Metrics

Primary:

- fully hidden-correct trials by arm.

Secondary:

- hidden cases passed per trial;
- provided visible-check invocations per hidden-correct trial;
- one-check solves;
- final nonblank source lines and UTF-8 source bytes;
- per-case failures grouped by each case's frozen `dimension` field;
- protocol deviations and infrastructure failures.

Wall-clock solver time is excluded because agent scheduling dominates it.
Candidate process duration may be retained as a diagnostic for timeout cases,
but it is not a comparative performance measure. Token counts may be recorded
by the orchestrator if exposed, but are not required by the filesystem
apparatus.

## Interpretation fixed in advance

- With three trials per arm, report individual rows and descriptive
  aggregates. Do not attach inferential significance.
- A 3/3, one-check result in both arms is a ceiling: it demonstrates that both
  documented paths were feasible for these agents, not that Tcl and Python are
  equivalent.
- Fewer repairs or less source in the machteld arm is evidence only about the
  convenience of this particular structured `run` surface on this task. It is
  not evidence that machteld or Tcl is generally superior.
- A Python repair around exceptions or timeout normalization is an API
  ergonomics observation, not evidence that Python cannot supervise processes.
- Inspect any failure before attributing it to a language; primer ambiguity,
  fixture behavior, encoding, checking, and subject protocol are alternative
  explanations.
- The experiment tests direct-child cleanup only. It makes no comparison of
  descendant-tree cleanup, resource limits, live streaming, packaging, GUI
  work, dependency footprint, or long-term maintenance.
- Do not tune this task, primer, or hidden set after seeing a trial and present
  a rerun as part of the frozen experiment. A revision receives a new
  experiment identifier.

## Known confounds

- Models have substantially more Python than Tcl in pretraining. That is part
  of the practical agent comparison, not removable noise.
- machteld provides a purpose-built native primitive while Python uses its
  standard library. That difference is the treatment being tested.
- The primers necessarily differ because the APIs differ, though neither
  includes a complete solution.
- The checker is written in Python, but both candidates and the neutral fixture
  run in fresh child processes under their native runtimes.
- The study is Windows-specific and deliberately restricts output to valid
  UTF-8, LF-free fixture framing, and less than 1 MiB per stream.
- The helper sleeps for five seconds against a 200 ms deadline, leaving a large
  margin for startup and scheduling variation.
