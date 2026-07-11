# Task: miller_rabin

miller_rabin(n): deterministic primality test using the fixed witness base set {2, 3, 5, 7}. Return 1 if n is prime, 0 if composite (and 0 for n < 2). This base set is PROVEN deterministic for all n < 3,215,031,751, and inputs are capped at n <= 3,037,000,499, so the answer is exactly true primality on the whole valid range. ALGORITHM: handle n<2 -> 0; for p in {2,3,5,7} if p|n then n is prime iff n==p; write n-1 = d*2^r with d odd; for each base a compute x = a^d mod n by fast modular exponentiation (square-and-multiply, reducing mod n every step), and if x != 1 and x != n-1, square up to r-1 times — if it never reaches n-1, a is a witness and n is composite. EDGE CASES / why it is hard: must catch the classic strong pseudoprimes that fool smaller base sets — 1373653 (sp to base 2,3) and 25326001 (sp to 2,3,5) are composite here because base 7 (and others) catch them; Carmichael numbers 561, 294409, 49141 must read composite; large primes 2147483647, 999999937, 3037000493, 1234567891 read prime.

Define **miller_rabin** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[2]` -> output `1`
- inputs `[561]` -> output `0`
- inputs `[1373653]` -> output `0`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
