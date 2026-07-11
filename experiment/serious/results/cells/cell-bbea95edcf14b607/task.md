# Task: zigzag_decode

Inverse of zigzag encoding: given a non-negative u (0 <= u < 2^63), return the signed n with dec(u) = (u >> 1) xor (-(u & 1)). Here (u>>1) is a LOGICAL right shift and -(u&1) is 0 when u is even, -1 (all ones) when u is odd — so even codes map to non-negative n and odd codes to negative n: dec(0)=0, dec(1)=-1, dec(2)=1, dec(3)=-2, dec(4)=2. Output range is [-2^62, 2^62-1]. Edge: dec(2^63-1) = -2^62, dec(2^63-2) = 2^62-1.

Define **zigzag_decode** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[0]` -> output `0`
- inputs `[1]` -> output `-1`
- inputs `[2]` -> output `1`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
