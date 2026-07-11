# Task: collatz_max

Maximum value reached during the Collatz trajectory of n. Starting from n, repeatedly apply the Collatz step until you reach 1: if the current value is even, divide by 2; if odd, compute 3*value + 1. Return the LARGEST value seen anywhere in the trajectory, INCLUDING the starting value n itself (so for n already a power-relevant small value the answer may be n). Conventions/edge cases: (1) the maximum includes the start, so collatz_max(1) = 1 and collatz_max(2) = 2 (the start is the max, never less); (2) odd n produces 3n+1 which can briefly exceed n, and these peaks are what you track (e.g. n=3 -> 3,10,5,16,8,4,2,1 -> max 16; n=7 -> max 52); (3) n <= 0 is invalid -> return 0 (do not attempt the iteration); (4) the trajectory always terminates at 1 for the tested inputs. The tested positive inputs are at most 1,000,000; use the exact Collatz recurrence. Inputs: any int64 (negatives/zero return 0); positive inputs up to 1e6 in tests. Output is the int64 max value reached.

Define **collatz_max** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[1]` -> output `1`
- inputs `[7]` -> output `52`
- inputs `[27]` -> output `9232`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
