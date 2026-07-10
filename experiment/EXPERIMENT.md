# Pre-registration: machteld/Tcl vs Python micro-pilot

**Frozen:** 2026-07-11, before blind machteld trials.

## Question

Can a fresh coding agent, given a compact factual Tcl primer, implement small
pure functions under machteld with correctness and iteration counts comparable
to ordinary Python?

This pilot validates the apparatus and detects gross fluency problems. Two
small tasks cannot establish that agents generally prefer Tcl, nor can they
measure the value of machteld's native palette or deployment model.

## Arms

- **machteld:** write `solution.tcl`; define the requested Tcl procedure; the
  checker loads it with `build/machteld.exe`.
- **python:** write `solution.py`; define the requested Python function; the
  checker imports it using the checker interpreter.

Each arm gets its own primer and otherwise receives the same task description,
visible cases, hidden cases, trial count, checker behavior, and timeout.

The machteld primer is part of the treatment: the thesis is that Tcl plus a
small in-context specification can offset its smaller pretraining corpus. The
Python primer is reused from the earlier Tika/Luax studies.

## Corpus slice

`gcd` is copied from the prior corpus. `sum_ints` retains all inherited cases
and adds four pre-trial conformance cases so its language-neutral ASCII-decimal
grammar is actually graded. Reference solutions are kept separately and never
copied into a solver sandbox.

| Task | Origin | Reason for inclusion |
|---|---|---|
| `gcd` | Tika corpus, later reused by Luax | One-shot loop/arithmetic calibration |
| `sum_ints` | Luax string extension | Intentional string/tokenization/validation stress task with prior repair iterations |

The original source hashes and exact provenance are recorded in
`corpus/PROVENANCE.md`.

Both arms are rerun with the same current model and protocol. Historical
Python/Luax outcomes informed this exploratory task selection but are not mixed
into the new result table.

## Trials and blindness

- 3 trials per task per arm: 12 fresh-agent trials total.
- One fresh agent per trial; no agent handles both arms or more than one trial.
- The agent receives one generated run directory and the exact prompt in
  `AGENT_PROMPT.md`.
- The agent must not inspect parent/sibling directories, prior solutions,
  hidden tests, or the internet.
- Only `instructions.md`, `primer.md`, `task.md`, `visible.json`, the empty
  solution file, and the provided check wrapper are present in its run
  directory.

The ordinary Codex shared filesystem is not a security boundary. Blindness is
procedural unless trials are later run inside an OS-level sandbox. This is a
known residual risk, not something the apparatus pretends to enforce.

Generated public artifacts are marked read-only and hashed in the manifest.
Attempt records live outside the solver cell. The grader reports any public
artifact/hash or attempt-log violation; these measures detect accidents but do
not replace filesystem isolation against a deliberately adversarial subject.

## Feedback and objective grading

Every `check` invocation:

1. loads the candidate in a fresh native-runtime process for each case;
2. evaluates all visible cases;
3. shows the first mismatch or native error/traceback;
4. appends one structured record to the supervisor-owned `attempts/<cell>.jsonl`.

After a trial ends, `grade_runs.py` evaluates the final solution against hidden
cases that were never copied into its sandbox. No subjective hand-grading is
used.

## Metrics

Primary:

- hidden-test solve rate by arm.

Secondary:

- visible-check invocations per solved trial;
- one-check solves;
- final nonblank source lines and bytes.

The iteration metric is specifically **provided-check invocations**, not every
edit or manual runtime invocation. A hidden-correct trial with no logged visible
green is retained for correctness, flagged as a protocol deviation, and
excluded from iteration aggregates.

Wall time is excluded because agent scheduling dominates it. Token usage is not
available to the filesystem harness; an orchestrator may record it separately,
but it is not part of this pilot's primary result.

## Interpretation fixed in advance

- This is a **pilot**, so report individual rows and descriptive aggregates;
  do not attach inferential significance to 6 trials per arm.
- This slice was selected with knowledge of earlier Luax outcomes, so it is
  exploratory. `gcd` previously ceilinged; `sum_ints` did not always do so.
- A 100%/one-check ceiling means the tasks were useful only for apparatus
  validation. It is not evidence that the languages are equivalent.
- A machteld failure may identify a primer, feedback, checker, or Tcl-fluency
  problem. Inspect failures before attributing them to the language.
- The next experiment, if warranted, must be separately pre-registered and use
  a stateful task (the existing `kvstore` is one candidate) or a small
  application task that exercises machteld-specific capabilities.
- Pilot outcomes must not be used to tune these two task prompts or hidden cases
  and then rerun them as if they were fresh confirmatory evidence.

## Known confounds

- Models have much more Python than Tcl in pretraining. That is part of the
  practical comparison, not removable noise.
- The machteld primer is authored by machteld's developer; the Python primer is
  inherited. Neither contains task-specific examples.
- The checker is written in Python, but both candidate programs run in separate
  child processes and are judged against the same JSON cases.
- Tcl values cross the checker boundary as strings. The checker converts them
  according to the expected corpus type; this pilot uses only integer and
  string outputs.
- The derived `sum_ints` cases now cover underscores, non-ASCII digits, mixed
  whitespace, sign-only tokens, and signed zero, but remain a finite case set
  rather than a proof of its lexical grammar.
