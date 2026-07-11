# Task: isbn13_valid

ISBN-13 check-digit validity for a single int64 n holding the full 13-digit code, interpreted as EXACTLY 13 digits with implicit leading zeros (so valid range is 0..9999999999999). The code d1..d13 is valid iff w1*d1 + w2*d2 + ... + w13*d13 is divisible by 10, where weights alternate 1,3,1,3,...,1 by position from the LEFT (odd positions weight 1, even positions weight 3); the check digit d13 is at an odd position with weight 1. Return 1 if valid else 0. Edges that bite: (1) leading zeros are part of the fixed 13-digit framing - n=0 is '0000000000000', sum 0 -> VALID -> 1; (2) because the code is always 13 digits, the rightmost digit (d13) is ALWAYS weight 1 and the parity of weights from the right is fixed - so when scanning from the right, the weight pattern starts 1,3,1,3,... independent of how many leading zeros n has (do NOT key the weight off the count of significant digits!); (3) n<0 or n>9999999999999 -> 0 (e.g. (10000000000000,)->0, (-1,)->0); (4) all-nines 9999999999999 happens to be invalid here; (5) single small n like 1 -> 0, 10 -> 0. Classic trap: assigning weights from the LEFT requires knowing the digit count; scanning from the RIGHT with the fixed start weight 1 avoids that and is correct precisely because the code is exactly 13 digits.

Define **isbn13_valid** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[9780306406157]` -> output `1`
- inputs `[9783161484100]` -> output `1`
- inputs `[0]` -> output `1`

Write only `solution.py`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
