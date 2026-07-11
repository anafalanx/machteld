# Task: totient

totient(n): Euler's totient phi(n) = count of integers in [1, n] coprime to n, for n >= 1. Implemented by trial-division factorization: start result = n, and for each distinct prime p dividing n multiply result by (1 - 1/p), computed exactly as result -= result/p (result is always divisible by p at that point, so this is exact). CONVENTIONS / edge cases: (1) totient(1) = 1. (2) n <= 0 returns -1 (sentinel for invalid). (3) Must collect each prime only ONCE (fully strip p from the working copy before subtracting), and after the p*p<=nn loop, if a prime cofactor > 1 remains it contributes one more factor. (4) Prime n gives n-1 (e.g. totient(999983)=999982, totient(1000000007)=1000000006). (5) Prime powers: totient(49)=42, totient(1024)=512, totient(121)=110. Tested inputs are <= ~1e9, so trial division to sqrt(n) (~31623 steps) is fast.

Define **totient** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[1]` -> output `1`
- inputs `[36]` -> output `12`
- inputs `[0]` -> output `-1`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
