# Task: luhn_valid

Luhn (mod-10) checksum validity for the decimal digits of a single non-negative int64 n, where the rightmost digit is the check digit. Algorithm: scan digits from the RIGHT (rightmost = position 1). Leave odd-position digits as-is; DOUBLE every even-position digit and, if the doubled value exceeds 9, subtract 9. Sum all resulting values; the candidate is valid iff that sum is divisible by 10. Return 1 if valid, else 0. Conventions/edges that bite: (1) n's digits are exactly its decimal representation with NO synthetic leading zeros, so the position parity is fixed by how many digits n actually has; (2) n=0 is a single digit '0' (position 1, undoubled) giving sum 0 -> VALID -> 1; (3) any n<0 is invalid -> 0 (do NOT take abs); (4) single-digit n: valid iff that digit is 0 (e.g. 0->1, 5->0); (5) the signed-64-bit maximum 9223372036854775807 is included. Off-by-one trap: position parity is counted from the RIGHT, and the rightmost digit is position 1 (undoubled).

Define **luhn_valid** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[0]` -> output `1`
- inputs `[18]` -> output `1`
- inputs `[79927398713]` -> output `1`

Write only `solution.py`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
