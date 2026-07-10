# Corpus provenance

The pilot derives a two-task slice from the existing blind-agent corpus.
Language-specific reference implementations were removed from the task JSON.
`gcd` is unchanged; `sum_ints` retains every original visible and hidden case
and adds four lexical conformance cases before any machteld trial was run.

| Vendored task | Original file | Original SHA-256 |
|---|---|---|
| `gcd.json` | `_luax/experiment/tasks/gcd.json` (itself ported from Tika) | `E75F457AFA17D418221140DD11C08A2634E1EB3C4E6FCE6F01C2D862055D74FD` |
| `sum_ints.json` | `_luax/experiment/tasks/sum_ints.json` | `53B297E035BED92CA0727916EF5909E433D9F4C2A54F6E360E81112A94BB78E1` |

The original Python references are preserved as executable files under
`refs/python/`; equivalent Tcl references for the machteld arm are under
`refs/machteld/`.

`sum_ints` adaptations:

- the Python/Lua parser comparison became a language-neutral grammar: optional
  sign followed by ASCII digits 0-9;
- the inherited `nil` tag became `parsing`;
- hidden cases were added for underscores, non-ASCII digits, mixed whitespace,
  and sign-only/signed-zero tokens.

The derived task therefore keeps the original source hash as provenance but is
not represented as byte-identical reuse.
