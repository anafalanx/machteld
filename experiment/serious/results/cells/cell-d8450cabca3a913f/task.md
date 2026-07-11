# Task: fnv1a32

Compute the 32-bit FNV-1a hash over the 8 bytes of a 64-bit value n, processing bytes in LITTLE-ENDIAN order (least-significant byte first). n is any int64 (|n|<2^63) and is treated as its unsigned 64-bit two's-complement pattern, so negatives hash via their raw bytes (n=-1 -> eight 0xFF bytes). Algorithm: h = 2166136261 (offset basis); for i in 0..7: byte = (u >> (8*i)) & 0xFF; h = h xor byte; h = (h * 16777619) mod 2^32. Return h in [0, 2^32-1]. Extract each byte with a logical right shift by 8*i (so high bytes of negatives come through correctly), and keep h reduced mod 2^32 after every multiply with a 0xFFFFFFFF mask. fnv1a32(0)=2615243109.

Define **fnv1a32** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[0]` -> output `2615243109`
- inputs `[1]` -> output `1048580676`
- inputs `[255]` -> output `3892497018`

Write only `solution.py`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
