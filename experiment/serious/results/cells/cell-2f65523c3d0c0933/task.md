# Task: iban_check

ISO 7064 MOD 97-10 check-digit computation (the IBAN check-digit math). Arity 1 int: n >= 0, the numeric string for which to compute the two check digits. The result is the value C = 98 - ((n * 100) mod 97). Equivalently, with r = n mod 97, C = 98 - ((r*100) mod 97). The output is always in 2..98. Edge cases that make this hard: n==0 gives 98; the full int64 max 9223372036854775807 must work (gives 58); other representative values: n=1 -> 95, n=96 -> 4, n=97 -> 98, n=98 -> 95, n=100 -> 89. All remainder operations here use non-negative operands. The result is NOT simply n mod 97 - it is 98 minus the appended-two-zeros remainder.

Define **iban_check** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[0]` -> output `98`
- inputs `[97]` -> output `98`
- inputs `[1]` -> output `95`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
