# Task: upca_check

UPC-A check-digit COMPUTATION. Given the 11-digit data part as a single int64 body (interpreted as EXACTLY 11 digits with implicit leading zeros, valid range 0..99999999999), return the correct 12th check digit (0..9). Algorithm: number the 11 data digits 1..11 from the LEFT; let O = sum of digits in odd positions (1,3,5,7,9,11) and E = sum of digits in even positions (2,4,6,8,10); total = 3*O + E; the check digit is (10 - (total mod 10)) mod 10. Return -1 if body<0 or body>99999999999. Edges that bite: (1) leading zeros are load-bearing - body=0 is '00000000000' giving total 0 and check digit 0; (2) because the data part is exactly 11 digits, the RIGHTMOST data digit is position 11 (ODD from the left) so it gets weight 3 - when scanning from the right the weight pattern is 3,1,3,1,...; getting this parity wrong (treating rightmost as weight 1) is the classic bug; (3) the final '(10 - total mod 10) mod 10' must map a 0 remainder to check 0 (not 10) - the outer mod 10 matters; (4) out-of-range -> -1 (e.g. (100000000000,)->-1, (-1,)->-1); (5) single-digit body like 5 -> '00000000005' -> rightmost weight 3 -> 3*5=15 -> check (10-5)%10=5.

Define **upca_check** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[3600029145]` -> output `2`
- inputs `[1234567890]` -> output `5`
- inputs `[0]` -> output `0`

Write only `solution.py`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
