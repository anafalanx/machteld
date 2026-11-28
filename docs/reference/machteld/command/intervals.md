---
id: machteld/command/intervals
type: command
title: intervals
summary: Find uncovered portions of a closed integer range.
commands: intervals, intervals gaps
---

# intervals

## Synopsis

```tcl
intervals gaps ?-pairs? lower upper endpoints
```

## Arguments and options

Supply a closed query range and a flat list of alternating starts and ends.
All bounds are signed 64-bit integers. For an empty coverage list pass
`{}`. Endpoints may arrive in any order as pairs. Each start must be less
than or equal to its corresponding end. The query uses the same rule.

## Results

Returns the uncovered closed ranges within the query, ordered by start.
The default result is a flat list. With `-pairs`, each item is a
two-element list. Complete coverage yields an empty list.

## Errors

The error codes are `MACHTELD INTERVALS usage` for syntax,
`MACHTELD INTERVALS input` for invalid ranges or endpoints, and
`MACHTELD INTERVALS memory` for a workspace allocation failure.

## Lifetime and timeouts

The operation runs synchronously and returns a Tcl list. It retains no
handles or input storage after returning.

## Examples

```tcl
set missing [intervals gaps 1 9 {4 7 1 2}]
# missing is {3 3 8 9}
```

## Constraints

Duplicate, overlapping and adjacent intervals count as continuous coverage.
Coverage outside the query has no effect on the result. Values with a
different unit must be converted to a common unit before calling.

## Subcommands

<a id="gaps"></a>
### gaps

#### Synopsis

`intervals gaps ?-pairs? lower upper endpoints`

#### Arguments and options

The query includes both `lower` and `upper`. The input list is flat in both
result modes. `-pairs` selects nested output.

#### Results

With an empty input the entire query is uncovered. Each output range is
maximal within the query. A one-point gap has equal start and end.

#### Errors

The command rejects an odd endpoint count, invalid lists, integers outside
the signed 64-bit range and reversed bounds.

#### Lifetime and timeouts

The call completes before control returns. Temporary storage scales with
the number of supplied intervals.

#### Examples

```tcl
set spans [db eval {SELECT low, high FROM reserved_ranges}]
foreach {lo hi} [intervals gaps 1 100 $spans] {
    puts [list available $lo $hi]
}
```

Here `db` is an open SQLite connection and `low` and `high` are integer
columns. Reading both columns together produces the flat input directly.

#### Constraints

Each adjacent pair of input endpoints describes one closed interval.
The implementation checks all intervals, including those outside the query.

#### See also

`machteld/package/sqlite3`, `machteld/guide/application-compiler`.

## See also

`machteld/command/intervals#gaps`, `machteld/package/sqlite3`.
