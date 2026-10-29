---
type: guide
title: Native validation
description: Native safety regressions, analysis coverage, instrumentation limits, and measured worker costs.
---

# Native validation

Step 10 of stabilization adds repeatable, headless checks at the native
boundaries. These are development checks, not a claim of memory safety or
a release approval. The unsigned candidate reports runtime version 0.22;
its release gate must establish fresh candidate acceptance. The signed
release is untouched, and the measurements below remain their recorded
pre-candidate stabilization evidence.

The recorded stabilization runs used Windows 11 Pro x64, version 10.0.26200
(build 26200). Windows Server 2025 remains an intended target, not a separately
verified environment in these receipts. Platform policy and measured acceptance
are different claims; see the [contract](contract.md).

## Running it

Build deliberately with `z devbuild`, then run:

```powershell
./tools/test.ps1 -Group native-validation
```

Use `-Machteld`, `-CacheRoot`, and `-MsysRoot` to select existing artifacts.
The group never rebuilds the runtime or regenerates documentation. It compiles
small isolated fixtures, tests the selected executable, and runs
`tools/native-analysis.ps1`. The latter also works independently and retains
its compiler invocations, exit codes, logs, source hashes and capability results
under a fresh `out/native-analysis-*/report.json`. `fast` includes the inexpensive
JSON and filesystem adversarial regressions. Explicit `release` includes all
groups; public-network and visible-GUI acceptance remain separate opt-ins.

## Coverage and its limits

| Boundary | Repeatable check | What it does not prove |
| --- | --- | --- |
| Authored native code | GCC `-fanalyzer`, warnings as errors, required use-after-free diagnostic canary | Complete path coverage or absence of defects |
| Command-line construction | Golden vectors, allocation-failure injection, Unicode/CRT round trips, malformed argument checks | Every third-party application's private argument parser |
| Hash token allocation | Synthetic last-token/exhaustion test under undefined-behavior traps | Exhausting billions of tokens through the public interface |
| JSON | Existing JSONTestSuite plus fixed-seed malformed-byte mutations, NUL/Unicode keys and strings, depth composition, retained child values and repeated error paths | Unbounded fuzzing or heap-safety instrumentation |
| Filesystem/publication | Malformed path refusal preserves candidate/destination, exact Unicode filenames, synthetic final-path capacity boundary, checked allocation arithmetic | A transaction against hostile concurrent namespace changes |
| Store/HTTP ownership | Injected SQLite step/finalization errors and repeated-header key destruction | Instrumented SQLite internals or general database functionality |
| Process ownership | Reused/closed/transferred channels, bounded mixed operations, active-interpreter deletion, ConPTY lifetimes, child termination and handle/private-memory observations | All scheduler interleavings or interactive terminal behavior |
| Scaling | Idle children and pools at widths 1, 8 and 32; host handles, threads, private bytes, CPU time and cycle deltas | A portable performance threshold or total child memory |

In the recorded run, the pinned Windows GCC 16.1 toolchain could not link its
ASan or UBSan runtime libraries. The runner probes these capabilities each time
and records unavailable ones as **unsupported**. It did support
undefined-behavior trap instrumentation: clean canaries must succeed,
while signed-overflow and array-bounds negative canaries must trap. That
instrumentation runs over command-line/Unicode tests, JSON plus yyjson, and
the included hash/directory/store/HTTP boundary code. Tcl/Tk and SQLite dependencies
are not instrumented. No address-sanitizer, leak-sanitizer, or thread-sanitizer
coverage is claimed. Process counters and explicit ownership assertions
complement, but do not replace, those missing tools.

## Findings addressed

- Child cleanup formerly looked up pipes by reusable Tcl channel names. Closing
  an older child could therefore close another child's newly assigned pipes.
  Close handlers now invalidate the borrowed channel identity; cleanup verifies
  interpreter ownership and detaches callbacks before freeing child storage.
  Tokens are removed before closing channels, so a stacked-channel finalizer
  cannot re-enter `child close` and free the same child twice.
- Tcl's modified UTF-8 was passed directly into JSON. NUL strings could produce
  invalid JSON, and decoded NUL object keys were not reliably addressable.
  Conversions now explicitly cross the real UTF-8 boundary. Bytearray decode
  also no longer reinterprets malformed wire bytes as valid Unicode characters.
- Already-typed JSON subtrees could bypass the total nesting limit during
  composition. Their descendants now count toward that same limit.
- Publication paths containing NUL could silently target the prefix filename.
  Store paths containing invalid text could create an unintended replacement-
  character filename. Both refuse invalid path text before filesystem changes.
- Canonical-path lookup now requires the returned string length to be strictly
  below the supplied capacity. A synthetic equality response tests that guard;
  it is defensive hardening, not evidence of a reproduced live path-growth
  failure. Under the [Windows API contract](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew), a larger required capacity
  was already refused. Directory allocation growth also checks addition and
  multiplication bounds before allocation.
- Store result objects leaked on specific SQLite step/finalization failures.
  Explicit references now cover the error paths; finalization failure no longer
  masquerades as an absent key.
- Duplicate JSON object members and repeated HTTP headers now release redundant
  temporary Tcl key objects that the destination dictionary does not retain.
- Hash-context token exhaustion is refused before incrementing past the signed
  counter's limit, preserving existing tokens and one-shot hashing.

Malformed UTF-8 refusal is an intentional tightening of invalid-input behavior,
not a change to valid JSON. Existing implementation-defined corpus expectations
were corrected to describe the actual bytes being parsed.

## Measurements and decisions

The bounded baseline on this Windows host showed that channel-mode children
cost roughly four host threads each (a native monitor plus Tcl pipe helpers),
and capture-mode children roughly three. At 32 idle children, host thread
counts were about 135 and 103 respectively; private bytes were roughly 8.6 MiB
and 72 MiB. These are whole-host snapshots, not per-worker allocation promises.
Idle cycle counts increased with width; CPU-time counters sometimes rounded to
zero or a single 15.6 ms tick, so zero observed CPU time is not zero overhead.
The runner records fresh values on each invocation rather than enforcing a
machine-dependent timing threshold.

The current monitor design remains in place. The measurements make its thread
and capture-buffer cost explicit; a completion-port or other monitor redesign
requires a workload that justifies the added complexity and its own tests.

Two earlier toolchain observations now have direct checks. The real linked Tk
`TkTextPrintIndex` formats positions through `INT64_MAX` correctly without
creating a window; the earlier format-dialect warning does not demonstrate a
runtime truncation defect. The pinned assembler and linker cannot create output
under the tested CJK directory. ASCII build paths, including spaces, work; a
compiled executable copied to the Unicode directory runs. Keep native build
outputs on ASCII paths for this toolchain. Unicode runtime/deployment paths
are a separate, tested capability.

Release reconstruction, full target acceptance, signing, and publication gates
remain separate work. Documentation or diagnostic completion does not publish a
new artifact or replace the preserved signed release.
