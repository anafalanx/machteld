# Task: zigzag_encode

Protobuf zigzag encoding of a signed integer to a non-negative integer: enc(n) = (n << 1) xor (n >> 63), where (n >> 63) is an ARITHMETIC right shift (sign-extend) giving 0 for n>=0 and -1 (all ones) for n<0. Equivalently enc(n) = 2*n for n>=0 and -2*n-1 for n<0, interleaving negatives into odd codes: enc(0)=0, enc(-1)=1, enc(1)=2, enc(-2)=3, enc(2)=4. Critical: the input range is restricted to -2^62 <= n <= 2^62-1, and the result is in [0, 2^63-1]. enc(2^62-1)=2^63-2, enc(-2^62)=2^63-1.

Define **zigzag_encode** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[0]` -> output `0`
- inputs `[-1]` -> output `1`
- inputs `[1]` -> output `2`

Write only `solution.py`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
