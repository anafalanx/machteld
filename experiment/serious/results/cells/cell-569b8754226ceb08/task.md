# Task: leb128_length

Return the number of bytes in the unsigned LEB128 encoding of n, where n >= 0 (0 <= n < 2^63). LEB128 packs 7 payload bits per byte; the count is ceil(bitlength(n)/7) with a MINIMUM of 1 (so n=0 encodes to 1 byte, not 0). Equivalently: c=1; while n>127: n=n>>7 (logical); c+=1; return c. Watch the boundaries at multiples of 7 bits: leb128_length(127)=1, leb128_length(128)=2, leb128_length(16383)=2, leb128_length(16384)=3. For the max, leb128_length(2^63-1)=9 (63 bits -> ceil(63/7)=9). Output is in [1,9].

Define **leb128_length** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[0]` -> output `1`
- inputs `[127]` -> output `1`
- inputs `[128]` -> output `2`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
