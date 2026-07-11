# Task: rpn_eval

Evaluate a packed RPN (reverse-Polish) expression. Args: prog (tokens packed as 4-bit nibbles, read LSB-nibble first) and length (number of tokens to read, 0..8 are meaningful). Maintain a value stack starting empty with a MAXIMUM CAPACITY OF 4 values. For i = 0 .. length-1 read token = (prog >> (4*i)) & 0xF: tokens 0..9 are single-digit operands (push that digit); tokens 10/11/12/13 are the binary operators +,-,*,/ respectively (pop b=top, then a=next, compute a OP b, push the result); tokens 14 and 15 are no-ops (ignored). Division (token 13) truncates TOWARD ZERO (C-style: -7/2 = -3, not -4). The expression is arbitrary, so you must define behavior for malformed/overflowing-capacity inputs precisely: (1) pushing a digit when the stack already holds 4 values is IGNORED (the digit is dropped, stack unchanged); (2) an operator with fewer than 2 values on the stack is SKIPPED (no-op); (3) division or by zero: if b == 0 the result of that operation is defined to be 0 (push 0, do not error); (4) at the end, the answer is the TOP of the stack, or 0 if the stack is empty. (5) length < 0 is treated as 0 (empty -> 0); length > 8 is clamped to 8. Operand order matters: for tokens '2','5','+' (nibbles LSB-first 2,5,10) the stack is [2,5] then + gives 7; for '-' it is a-b with a the deeper value. Test inputs keep every value within int64. Output is the int64 result.

Define **rpn_eval** taking exactly 2 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[2642, 3]` -> output `7`
- inputs `[3124, 3]` -> output `12`
- inputs `[3334, 3]` -> output `0`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
