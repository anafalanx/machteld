# Task: multiorder

multiorder(a, n): the multiplicative order of a modulo n — the smallest positive integer k with a^k ≡ 1 (mod n). Return -1 if it does not exist, i.e. when n <= 1 OR gcd(a mod n, n) != 1 (a not a unit mod n). CONVENTIONS / edge cases: (1) Reduce a modulo n first and normalize negatives into [0,n) (if the remainder is negative, add n); e.g. multiorder(-3,7)=multiorder(4,7)=3. (2) n <= 1 returns -1. (3) If gcd(a,n) != 1 (e.g. a=0; a=6,n=9; a=2,n=4; a=4,n=6) return -1. (4) When a ≡ 1 (mod n) the order is 1 (e.g. multiorder(10,9)=1). (5) Compute by iterated multiplication mod n (cur = cur*a mod n) counting steps until cur == 1 — never use a precomputed phi; the order need not divide an obvious bound for composite n. The input domain is limited to n <= 3037000499; tested moduli are <= ~1e6 with small orders for speed.

Define **multiorder** taking exactly 2 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[2, 7]` -> output `3`
- inputs `[6, 9]` -> output `-1`
- inputs `[10, 9]` -> output `1`

Write only `solution.py`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
