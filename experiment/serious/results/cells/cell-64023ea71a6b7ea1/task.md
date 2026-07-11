# Task: semver_cmp

Compare two semantic versions and return -1, 0, or 1 (a<b, a==b, a>b). Arity 4 ints: (a, apre, b, bpre). a and b are each a packed core version = major*1000000 + minor*1000 + patch, with minor and patch in 0..999 (so the packed core is monotonic and a plain integer compare on cores is correct). apre and bpre are pre-release tags: 0 means a normal release (no pre-release), and any value >0 means a pre-release whose numeric id is that value. SemVer precedence rules: first compare the cores a vs b; if they differ that decides the result. ONLY when the cores are equal do the pre-release tags matter: a normal release (pre==0) has HIGHER precedence than ANY pre-release (pre>0) of the same core; if both are pre-releases, the one with the smaller pre id is lower; if both are releases they are equal. So 1.0.0 > 1.0.0-1, and 1.0.0-1 < 1.0.0-2. Edge cases: equal cores with one release and one pre-release; both pre-release with different ids; both release (tie); the pre fields are irrelevant whenever the cores already differ. All inputs are non-negative and fit comfortably in int64.

Define **semver_cmp** taking exactly 4 argument(s) and returning
1 value. Outputs are integer or string values as described;
an expected `FAIL` means the procedure/function must raise an error.

Visible examples:

- inputs `[1000000, 0, 1000000, 5]` -> output `1`
- inputs `[1000000, 3, 1000000, 7]` -> output `-1`
- inputs `[2003001, 0, 2003000, 0]` -> output `1`

Write only `solution.tcl`. Run `check.cmd` for visible feedback. At most
8 checks are available. Hidden cases are graded after the
trial, so implement the full specification.
