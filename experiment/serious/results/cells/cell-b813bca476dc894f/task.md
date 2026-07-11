# Task: modinv

modinv(a, m): the modular multiplicative inverse of a modulo m, computed via the extended Euclidean algorithm. Return the unique inverse in the range [0, m), i.e. the x with (a*x) mod m == 1 and 0 <= x < m. Return -1 when no inverse exists, which is exactly when gcd(a mod m, m) != 1 (this includes a ≡ 0). CONVENTIONS / edge cases: (1) m <= 1 always returns -1 (there is no nonzero residue to invert; m=1 and m=0 and negative m all give -1). (2) a may be any int64, including negative or >= m; reduce a modulo m first, and because the result must lie in [0,m) you must normalize the Bezout coefficient into that range (add m if negative). If the remainder is negative, add m. (3) Non-coprime inputs (e.g. modinv(6,9), modinv(2,4), modinv(46,128)) return -1. Tested |a| and m values are below ~2e9.

Define **modinv** taking exactly 2 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[2, 7]` -> output `4`
- inputs `[6, 9]` -> output `-1`
- inputs `[-3, 11]` -> output `7`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
