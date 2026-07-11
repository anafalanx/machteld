# Task: kvstore

An in-memory integer key-value store with NESTED transactions, driven by a list of command strings. Given one argument cmds (an array of command strings), process each command IN ORDER against an initially-empty store, and return a SINGLE string: the outputs of all output-producing commands joined by a newline ("
"). If no command produces output, return the empty string "". Keys are non-empty tokens; values are decimal integers (possibly negative). Each command is a single line split on spaces (runs of spaces and leading/trailing spaces collapse; empty tokens are dropped). The commands are: SET k v -- set key k to integer v (no output); GET k -- output the current value of k as a decimal string, or "NULL" if k is not set; UNSET k -- remove key k (no-op if absent; no output); COUNT v -- output (as a decimal string) how many keys are currently set to the integer value v; BEGIN -- open a new transaction block (transactions NEST; no output); ROLLBACK -- undo ALL changes made since the most recent still-open BEGIN and close that one transaction; if there is NO open transaction, output "NO TRANSACTION"; COMMIT -- permanently apply ALL currently-open transactions, closing them all (no output; a no-op with no output if no transaction is open). Transaction semantics (the crux): changes (SET/UNSET) made while transactions are open are provisional; ROLLBACK undoes the most recent transaction's changes, restoring each touched key to the value it had when that BEGIN executed -- this includes restoring a key that was UNSET, and removing a key that was newly SET. COMMIT closes all open transactions at once, keeping their changes. GET and COUNT always read the CURRENT (provisional) state. Nested example: SET a 1; BEGIN; SET a 2; BEGIN; SET a 3; ROLLBACK (a back to 2); GET a => "2"; ROLLBACK (a back to 1); GET a => "1". MALFORMED commands make the WHOLE run FAIL: an unrecognized command word; the wrong number of tokens for a command (e.g. GET with 0 or 2+ args, "SET a" missing the value, "BEGIN x" with an arg); or a value token (SET's v, COUNT's v) that is not a valid decimal integer. A valid value is a base-10 numeral consisting of an optional +/- sign followed by one or more ASCII digits (0-9) and NOTHING ELSE -- so floats like "1.5", hex like "0x1A", junk like "abc", and any token containing embedded whitespace (e.g. a tab or newline that survived tokenizing, since tokens split only on the space character) are all rejected. Values are bounded to the signed 64-bit range [-2^63, 2^63-1] = [-9223372036854775808, 9223372036854775807]; a numeral whose magnitude lies outside that range (e.g. "9223372036854775808" or "99999999999999999999") is MALFORMED and fails the run. Command words are case-sensitive ("set" is unknown). This is a fallible operation: a malformed command must make the call raise an error. A failure test case expects the call to fail, written as the marker "FAIL" in place of the expected-outputs list. Examples: ["SET a 10","GET a","GET b"] => "10
NULL"; ["SET a 1","BEGIN","SET a 2","GET a","ROLLBACK","GET a"] => "2
1"; ["SET a 5","COUNT 5","SET b 5","COUNT 5","UNSET a","COUNT 5"] => "1
2
1"; the empty command list [] => "".

Define **run** taking one argument and returning one string. An expected `FAIL`
means the procedure/function must raise an error.

Visible examples:

- inputs `[["SET a 10", "GET a", "GET b"]]` -> output `"10\nNULL"`
- inputs `[["SET a 1", "BEGIN", "SET a 2", "GET a", "ROLLBACK", "GET a"]]` -> output `"2\n1"`
- inputs `[["SET a 5", "COUNT 5", "SET b 5", "COUNT 5", "UNSET a", "COUNT 5"]]` -> output `"1\n2\n1"`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded afterward.
