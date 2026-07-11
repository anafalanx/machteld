# Task: isbn10_valid

ISBN-10 check-digit validity, taking TWO int64 args: body (the first 9 digits as an integer, interpreted as EXACTLY 9 digits with implicit leading zeros) and check (the 10th/check digit value, 0..10 where 10 represents the literal 'X'). The full code d1..d10 is valid iff sum_{i=1..10} (11-i)*d_i is divisible by 11; equivalently 10*d1 + 9*d2 + ... + 2*d9 + 1*d10 == 0 (mod 11), with d10 = check weighted 1. Return 1 if valid else 0. Edges that bite: (1) leading-zero handling is EXPLICIT and load-bearing - body=0 means '000000000' so a code like (0,0) is valid (sum 0) -> 1, and body=19852663 means '019852663' (a leading zero) - positions/weights are assigned by digit place, leading zeros contribute 0 but you must not misalign weights; (2) only the CHECK digit may be 10 ('X'); check must be in 0..10, otherwise -> 0 (e.g. (0,11)->0); (3) body must be in 0..999999999, otherwise -> 0 (e.g. (-1,0)->0, (1000000000,0)->0); (4) the 'X'=10 case is real and tested (97522980,10)->1. Weight trap: when scanning body from the right the weights run 2,3,4,... (rightmost body digit d9 has weight 2), and check has weight 1.

Define **isbn10_valid** taking exactly 2 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[30640615, 2]` -> output `1`
- inputs `[97522980, 10]` -> output `1`
- inputs `[0, 0]` -> output `1`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
