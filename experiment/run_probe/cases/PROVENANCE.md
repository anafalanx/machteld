# Case provenance

`run_probe` is a new process-control task assembled before any subject trial.
Its vectors are adapted from existing machteld execution tests rather than
invented after seeing model behavior.

The following behaviors come from `test/run_test.tcl`:

- completed status, exit code, and captured stdout;
- preservation of a nonzero exit (this small fixture freezes exit 7; the
  existing wide-exit case motivated exact-code handling but is not retained);
- argv round-trips containing spaces, quotes, and backslashes;
- bounded termination of a slow child.

The quoting and hostile-string slice is adapted from
`test/cmdline_test.c`, especially its vectors for empty arguments, embedded
quotes, backslashes, shell metacharacters, and percent-delimited environment
syntax. This experiment launches a native executable directly; it does not
exercise the batch-file-specific escaping path from that test.

Before trials, the slice was extended with:

- separate stdout and stderr capture;
- valid UTF-8 payloads containing non-ASCII text;
- an empty payload;
- one 4096-byte capture case;
- a PID-backed check that the directly launched hanging helper is dead when
  the candidate returns.

The neutral fixture's behavior and all three visible plus six hidden cases are
frozen with the apparatus. Results from the earlier pure-function pilot were
used only to motivate moving to a process task; no solution or outcome from
that pilot is included in this corpus.
