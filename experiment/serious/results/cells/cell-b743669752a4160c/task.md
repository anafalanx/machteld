# Task: roman_value

Roman-numeral value with strict validity. Arity 1 int: n encodes a roman numeral as its base-10 digits, most-significant digit = leftmost symbol, where each digit is a symbol code: 1=I(1), 2=V(5), 3=X(10), 4=L(50), 5=C(100), 6=D(500), 7=M(1000). Example: XIV = X,I,V = codes 3,1,2 => n=312. Return the integer value if n is a WELL-FORMED standard roman numeral in 1..3999, else return -1. n<=0 returns -1; any digit 0 or 8 or 9 (not a valid symbol code) makes it invalid (-1). Validity is strict canonical subtractive form: compute the value by the standard right-to-left rule (a symbol with value less than the running maximum seen to its right is subtracted, otherwise added and becomes the new max), then accept ONLY if the canonical roman representation of that value re-encodes to exactly the same code sequence n. This rejects non-canonical forms like IIII (1111->-1), VV (22->-1), XM (37->-1), IL (14->-1), MMMM (7777->-1) and forms outside 1..3999, while accepting IV(12->4), IX(13->9), XIV(312->14), MCMXCIV(7573512->1994), MMMCMXCIX(777573513->3999), XL(34->40), XCIX(3513->99), CD(56->400). The canonical-roundtrip is the crux: subtractive parse value alone is not enough - you must regenerate the canonical packed code sequence (greedy over M,CM,D,CD,C,XC,L,XL,X,IX,V,IV,I, building pack = pack*10 + each emitted code) and compare it to n.

Define **roman_value** taking exactly 1 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[312]` -> output `14`
- inputs `[7573512]` -> output `1994`
- inputs `[14]` -> output `-1`

Write only `solution.py`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
