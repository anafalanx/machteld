# Task: regmachine

Decode and run a packed tiny register machine. Args: prog (a program packed as 4-bit instructions, read LSB-nibble first) and k (a step budget). The machine has a single accumulator acc that starts at 0 and a program counter pc that starts at 0 (counting in nibbles). There are 16 nibble slots (so pc ranges 0..15). Execute up to k steps: each step reads the opcode = (prog >> (4*pc)) & 0xF, executes it, and (unless it was a conditional skip) advances pc by 1. Halt when k steps have been taken OR pc reaches 16 OR a HALT opcode is hit; then return acc. Opcodes: 0=HALT (stop immediately, return current acc), 1=acc+1, 2=acc-1, 3=acc*2, 4=acc=-acc, 5=acc=acc/2 (integer division truncating TOWARD ZERO, C-style: -3/2 = -1, not -2), 6=acc+3, 7=acc-5, 8=SKIPZ (if acc==0, advance pc by 2 -- skipping the next instruction -- otherwise pc+1; either way it costs one step), 9=SKIPNZ (if acc!=0, advance pc by 2, else pc+1), 10=acc*3, 11=acc=acc mod 2 (C-style remainder with the SIGN OF acc: -3 mod 2 = -1, not 1), 12=acc=abs(acc), 13=acc=0, 14=acc+2, 15=acc-2. Tricky points: (1) a SKIP at the last reachable nibble simply runs out of program (pc>=16) and halts; (2) HALT does NOT consume a normal step-advance, it just stops; (3) k < 0 is invalid -> return 0; (4) k can be larger than 16 (the pc>=16 bound stops execution); (5) opcodes 5 and 11 use the specified truncation and signed-remainder semantics for negative values. Test inputs keep acc within int64 throughout. Output is the final accumulator.

Define **regmachine** taking exactly 2 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[801, 3]` -> output `0`
- inputs `[136, 5]` -> output `0`
- inputs `[45602, 4]` -> output `-1`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
