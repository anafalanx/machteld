# Task: mod97_checkdigits

ISO 7064 MOD 97-10 (IBAN-style) check-digit computation. Given a non-negative integer n (0..10^18-1), return the UNIQUE C in [0,96] such that (n*100 + C) is congruent to 1 (mod 97). Closed form: C = (1 - (n*100 mod 97)) mod 97, taking the NON-NEGATIVE representative. Return -1 if n<0 or n>999999999999999999 (10^18-1). Equivalent form and edge cases: (1) EQUIVALENT REDUCTION - r = ((n mod 97) * 100) mod 97 may be used before the final adjustment; (2) SIGN of remainder - 1 - r can be negative (down to -95), so normalize it into [0,96]; (3) boundary values: n=0 -> 1, n=97 -> 1 (since 97 mod 97 = 0), n=1 -> 95; (4) out-of-range exactly at 10^18 -> -1.

Define **mod97_checkdigits** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[0]` -> output `1`
- inputs `[1]` -> output `95`
- inputs `[97]` -> output `1`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
