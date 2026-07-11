# Task: crt2

crt2(r1, m1, r2, m2): solve the system x ≡ r1 (mod m1) and x ≡ r2 (mod m2) by the (non-coprime) Chinese Remainder Theorem. Return the smallest NON-NEGATIVE solution x in [0, lcm(m1,m2)), or -1 if no solution exists. CONVENTIONS / edge cases: (1) m1 <= 0 or m2 <= 0 returns -1. (2) Residues r1, r2 may be any int64 (including negative or >= modulus): reduce each into [0, m) first (if the remainder is negative, add the modulus). (3) A solution exists iff (r2 - r1) is divisible by g = gcd(m1, m2); otherwise return -1 (e.g. crt2(1,4,2,6)=-1, crt2(0,2,1,2)=-1). (4) When it exists, x = r1 + m1*t (mod lcm) where t = ((r2-r1)/g) * inv(m1/g mod m2/g) mod (m2/g); compute the modular inverse via extended Euclid. (5) lcm = (m1/g)*m2; answer normalized into [0, lcm). Test inputs have m1 and m2 <= 1e9; their lcm and the expected answer fit signed 64-bit integers. Example with large coprime moduli: crt2(0,1000000000,1,999999999)=1000000000.

Define **crt2** taking exactly 4 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[2, 3, 3, 5]` -> output `8`
- inputs `[1, 4, 2, 6]` -> output `-1`
- inputs `[0, 4, 2, 6]` -> output `8`

Write only `solution.py`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
