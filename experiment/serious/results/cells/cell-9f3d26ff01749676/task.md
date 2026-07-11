# Task: sum_of_two_squares

sum_of_two_squares(n): return 1 if n can be written as a^2 + b^2 for some integers a, b >= 0 (zero allowed), else 0. By the sum-of-two-squares theorem this holds iff in the prime factorization of n every prime p ≡ 3 (mod 4) appears to an EVEN power. CONVENTIONS / edge cases: (1) n < 0 -> 0 (negative numbers are not sums of two squares). (2) n = 0 -> 1 (0 = 0^2 + 0^2). (3) n = 1 -> 1, n = 2 -> 1, n = 4 -> 1 (=0+4). (4) Primes p ≡ 3 (mod 4) like 3, 7, 11 -> 0; but their even powers like 9 (=3^2 -> 0+9) and 49 (=7^2) and 121 (=11^2) -> 1. (5) The factor 2 and primes ≡ 1 (mod 4) never block. Tricky composites: 21 = 3*7 -> 0 (two distinct 3-mod-4 primes, each odd power); 45 = 9*5 -> 1; 325 = 25*13 -> 1; 1105 -> 1; 999999 = 3^3*7*11*13*37 -> 0 (3 appears cubed); 999999999 -> 0. Implementation: trial-divide n, for each prime count its exponent, and if p%4==3 with odd exponent answer 0; after stripping factors up to sqrt, a leftover prime cofactor > 1 with cofactor%4==3 (exponent 1) gives 0. Tested inputs are <= ~1e9, so trial division to sqrt is fast.

Define **sum_of_two_squares** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[0]` -> output `1`
- inputs `[3]` -> output `0`
- inputs `[45]` -> output `1`

Write only `solution.py`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
