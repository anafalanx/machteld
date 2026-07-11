# Task: gray_decode

Decode a reflected binary Gray code: given g (0 <= g < 2^63), return the n such that gray_encode(n) = n xor (n>>1) = g. The decode is the prefix-xor: n = g xor (g>>1) xor (g>>2) xor ... down to 0. Implement by accumulating: n=g; s=g>>1; while s!=0: n^=s; s>>=1 (all shifts LOGICAL/zero-fill since g>=0). This is a genuine fixed-point loop, NOT a single xor — gray_decode(7)=5 (not 7), gray_decode(8)=15, gray_decode(255)=170. Edge: gray_decode(0)=0, gray_decode(1)=1, gray_decode(2^63-1)=6148914691236517205. Output is in [0, 2^63-1] and is itself non-negative.

Define **gray_decode** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[0]` -> output `0`
- inputs `[1]` -> output `1`
- inputs `[7]` -> output `5`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
