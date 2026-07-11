# Task: popcount

Return the number of set (1) bits in the 64-bit two's-complement representation of n. n is any int64 (range [-2^63, 2^63-1]), INCLUDING negatives: a negative n is interpreted via its raw two's-complement bit pattern, so popcount(-1) = 64 (all bits set), popcount(-2) = 63, and popcount(MIN64 = -2^63) = 1 (only the sign bit set). For n >= 0 it is the ordinary binary 1-count: popcount(0)=0, popcount(255)=8, popcount(2^63-1)=63. Iterate all 64 bit positions using a logical right shift (zero-fill) so the sign bit does not smear; arithmetic shift here would over-count. Output is in [0,64].

Define **popcount** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[0]` -> output `0`
- inputs `[1]` -> output `1`
- inputs `[255]` -> output `8`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
