# Task: jacobi

jacobi(a, n): the Jacobi symbol (a/n) for an ODD positive modulus n (n >= 1). Returns one of -1, 0, +1. Algorithm: reduce a modulo n (normalizing a negative residue into [0,n) by adding n when needed), then repeatedly factor out powers of 2 flipping the sign when n ≡ 3 or 5 (mod 8), apply quadratic reciprocity flipping the sign when both a ≡ 3 and n ≡ 3 (mod 4), and swap. At the end the symbol is the running sign if the reduced n == 1, otherwise 0 (meaning gcd(a,n) > 1). CONVENTIONS / edge cases: (1) n is guaranteed odd and >= 1 — no even-n or n<=0 inputs are tested. (2) (a/1) == 1 for every a, including a=0 (jacobi(0,1)=1). (3) jacobi(0,n)=0 for n>1. (4) When gcd(a,n)>1 (e.g. a=7,n=7; a=3,n=3; a=5,n=5) the result is 0. (5) Negative a is reduced first (jacobi(-5,21)=jacobi(16,21)=1; jacobi(-1,7)=-1). Tested n values are below ~30000; tested a values are modest signed integers.

Define **jacobi** taking exactly 2 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[5, 21]` -> output `1`
- inputs `[30, 59]` -> output `-1`
- inputs `[0, 1]` -> output `1`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
