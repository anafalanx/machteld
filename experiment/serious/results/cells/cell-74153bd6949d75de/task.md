# Task: damm_valid

Damm check-digit validity. Arity 1 int: n. n encodes a decimal string (its base-10 digits, most-significant first), the LAST digit being the appended Damm check digit. Return 1 if the string is valid under the Damm algorithm, else 0. Negative n returns 0. The Damm algorithm uses the standard order-10 totally anti-symmetric quasigroup operation table T (the classic Damm table). Process the digits left-to-right: start interim=0; for each digit d, interim = T[interim][d]. The string is valid iff the final interim == 0. The table (rows indexed by interim 0..9, columns by d 0..9) is: row0 0317598642, row1 7092154863, row2 4206871359, row3 1750983426, row4 6123045978, row5 3674209581, row6 5869720134, row7 8945362017, row8 9438617205, row9 2581436790. Edge cases: n==0 is the single digit 0, and since interim starts at 0 and T[0][0]=0 it is VALID (returns 1); any single nonzero digit is invalid (T[0][d]!=0 for d!=0); leading-zero handling is implicit (the integer encoding has none), so process exactly the digits present; values through 9223372036854775807 contain up to 19 digits and must all be processed.

Define **damm_valid** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[5724]` -> output `1`
- inputs `[572]` -> output `0`
- inputs `[0]` -> output `1`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
