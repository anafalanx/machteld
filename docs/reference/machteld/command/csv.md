---
id: machteld/command/csv
type: command
title: csv
summary: CSV text decoded to rows of fields, and rows encoded back to CSV.
commands: csv
---

# csv

## Synopsis

```tcl
csv decode text ?-sep char?
csv encode rows ?-sep char? ?-eol lf|crlf|cr?
```

## Behavior

`decode` returns a list of records; each record is a Tcl list of fields.
`encode` is the inverse: it takes such a list and returns CSV text with
every record terminated.

The decode contract is a port of the CPAN reference implementation
Text::CSV_XS (binary mode, default settings), and was differential-tested
against it: the same inputs produce the same rows, and the same inputs are
refused. The rules:

- Fields are separated by `-sep` (default `,`, always a single character,
  never a quote or line-ending character).
- CR, LF, and CRLF all terminate a record; a bare CR is a record end. The
  final record may end at end of input without a terminator.
- A field starting with `"` is quoted: separators, CR, LF, and CRLF inside
  it are literal content, and `""` is a literal quote. The closing quote
  must be followed by a separator, a record end, or end of input.
- An empty line is a record with one empty field. Empty input is no
  records. CSV cannot represent a record with zero fields.

Rows compose directly with `macht`:

```tcl
set h [macht load [csv decode $text] -schema {pad s status i bytes i}]
macht sum {$bytes} where {$status == 404} -data $h
```

`encode` quotes a field only when it contains the separator, a quote, CR,
or LF. That is less quoting than some writers produce (Text::CSV_XS also
quotes spaces by default); the claim `encode` makes is round-trip fidelity,
not byte-identity: `csv decode [csv encode $rows]` is `$rows`, and a
conforming reader decodes the same rows. `-eol` selects the record
terminator written (`lf` default, `crlf` for interchange with Windows
tools, `cr` for completeness).

## Errors

All failures raise `{MACHTELD CSV code}`:

- `parse` — malformed CSV on decode: a quote inside an unquoted field,
  text after a closing quote, or end of input inside a quoted field. The
  message names the record and character position.
- `badvalue` — a bad `-sep` or `-eol` value, or `encode` given a value
  that is not a list of records.
- `usage` — an unknown subcommand or option, or a missing argument.

Whitespace is never trimmed: a space before an opening quote makes the
field unquoted, and the quote inside it is then a `parse` error — the same
refusal Text::CSV_XS makes by default.
