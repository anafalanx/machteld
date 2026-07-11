# Task: damm_check

Damm-algorithm check digit for the decimal digits of a non-negative integer n (0..10^18-1). The Damm algorithm uses a fixed 10x10 totally anti-symmetric quasigroup table T (the standard one whose diagonal is all zeros). Starting with interim=0, process the digits of n strictly LEFT-TO-RIGHT, updating interim = T[interim][digit] for each digit; the final interim value is the check digit returned (0..9). Standard table rows T[0..9]: [0,3,1,7,5,9,8,6,4,2],[7,0,9,2,1,5,4,8,6,3],[4,2,0,6,8,7,1,3,5,9],[1,7,5,0,9,8,3,4,2,6],[6,1,2,3,0,4,5,9,7,8],[3,6,7,4,2,0,9,5,8,1],[5,8,6,9,7,2,0,1,3,4],[8,9,4,5,3,6,2,0,1,7],[9,4,3,8,6,1,7,2,0,5],[2,5,8,1,4,3,6,7,9,0]. Return -1 if n<0 or n>999999999999999999. Edges that bite hard: (1) ORDER MATTERS - Damm is NOT symmetric, you MUST consume digits most-significant first; the usual right-to-left digit-peel is WRONG here; process the actual decimal digits from left to right; (2) leading-zero framing: n's digits are exactly its decimal form (no padding); n=0 -> single digit 0 -> T[0][0]=0; n=1 -> T[0][1]=3; (3) use the supplied quasigroup table exactly; (4) a number plus its own Damm check digit appended has Damm value 0 (e.g. 572 -> 4, and 5724 -> 0).

Define **damm_check** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[572]` -> output `4`
- inputs `[5724]` -> output `0`
- inputs `[1]` -> output `3`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
