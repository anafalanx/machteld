# Task: reverse_bits

Given (n, w), reverse the low w bits of n and return the result as a non-negative integer. w is in [1,63]. Only the low w bits of n participate: bit i (for i in [0,w-1]) of n becomes bit (w-1-i) of the result; all bits of n at position >= w are IGNORED (not just zeroed afterward — they must never leak into the answer). n may be negative; use its low w two's-complement bits (extract each bit with a logical right shift then mask with 1). Examples: reverse_bits(178,8): 178=0b10110010 reverses to 0b01001101=77. reverse_bits(1,8)=128 (bit0 -> bit7). reverse_bits(1,1)=1. reverse_bits(-1,8)=255 (low 8 bits all 1). reverse_bits(1,63)=2^62. Output is in [0, 2^w - 1].

Define **reverse_bits** taking exactly 2 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[178, 8]` -> output `77`
- inputs `[1, 8]` -> output `128`
- inputs `[1, 1]` -> output `1`

Write only `solution.py`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
