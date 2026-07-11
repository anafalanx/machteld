# Task: extract_bits

Bitfield extraction. Arity 3 ints: (value, lo, width). Interpret value as its raw 64-bit two's-complement pattern. Extract the contiguous bit run [lo, lo+width): the width bits starting at bit position lo (bit 0 = least significant). Constraints honored by inputs: lo in 0..63, width in 0..(64-lo). Return the extracted bits as a signed int64 obtained by reinterpreting the width-bit unsigned chunk as a two's-complement int64 (so for width==64, -1 in -> -1 out; for width<64 the result is the non-negative chunk value). Edge cases that make this hard: width==0 must return 0 regardless of lo; width==64 (only possible when lo==0) returns value unchanged including negative values; the right shift must be LOGICAL (zero-fill), not arithmetic, so the high bits of a negative value do not leak in; extracting bit 63 of INT64_MIN yields 1; extracting bit 0 of -2 yields 0 while bit 1 yields 1.

Define **extract_bits** taking exactly 3 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[3735928559, 4, 8]` -> output `238`
- inputs `[-1, 0, 1]` -> output `1`
- inputs `[5, 1, 2]` -> output `2`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
