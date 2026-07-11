# Task: bracket_balanced

Bit-encoded bracket-balance checker. Args: n (the bit pattern) and length (how many brackets to read). Read length brackets from the bits of n, LSB first: bit i (i = 0 .. length-1) is bit (n>>i)&1; a 0 bit means an OPEN bracket '(' and a 1 bit means a CLOSE bracket ')'. Maintain a running depth starting at 0: open adds 1, close subtracts 1. Return 1 if the sequence is balanced (depth returns to exactly 0 after all length brackets) AND the depth NEVER goes negative at any prefix; otherwise return 0. Edge/convention rules that make it tricky: (1) length == 0 is the empty sequence, which is balanced -> return 1; (2) length < 0 is invalid -> return 0; (3) a sequence may end at depth 0 yet still be invalid if it dipped below 0 partway (e.g. ')(' -> return 0), so you must check the never-negative condition on every prefix, not just the final depth; (4) reading is strictly LSB-first, so the FIRST bracket is the lowest bit; (5) only the low `length` bits matter, higher bits of n are ignored. Inputs: n >= 0, 0 <= length <= 62 in the test set (plus the length<0 invalid case). Output is exactly 1 or 0.

Define **bracket_balanced** taking exactly 2 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[0, 0]` -> output `1`
- inputs `[1, 2]` -> output `0`
- inputs `[2, 2]` -> output `1`

Write only `solution.py`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
