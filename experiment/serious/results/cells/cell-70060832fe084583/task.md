# Task: date_valid

Proleptic-Gregorian calendar date validity. Arity 1 int: d, a packed date yyyymmdd = year*10000 + month*100 + day. Return 1 if it is a real calendar date, else 0. Rules: d<=0 returns 0. Decompose day=d%100, month=(d//100)%100, year=d//10000. Valid requires year in 1..9999, month in 1..12, day>=1, and day <= the number of days in that month. Month lengths: Jan31 Feb28/29 Mar31 Apr30 May31 Jun30 Jul31 Aug31 Sep30 Oct31 Nov30 Dec31. February has 29 days iff the year is a Gregorian leap year: divisible by 4 AND (not divisible by 100 OR divisible by 400). Edge cases that make this hard: 1900 is NOT a leap year (div by 100 not 400) so 19000229 is invalid; 2000 and 1600 ARE leap years (div by 400) so 20000229 and 16000229 are valid; 2024 is leap (20240229 valid); months >12 or ==0 invalid (20231301, 20230001); day 0 invalid (20230100); day 31 in a 30-day month invalid (20230631, 20231131); boundary 99991231 valid and 10101 (year1 jan 1) valid; the packed form means a value like 20231301 must be rejected even though it looks numeric.

Define **date_valid** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[20000229]` -> output `1`
- inputs `[19000229]` -> output `0`
- inputs `[20231131]` -> output `0`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
