---
id: machteld/command/links
type: command
title: links
summary: Inventory reparse points and optional hard-linked files in a Windows tree.
commands: links
---

# links

## Synopsis

```tcl
links root ?-depth nonnegativeInteger? ?-prune patterns? ?-hardlinks?
```

## Arguments and options

`root`, `-depth`, and `-prune` follow the `dirs` contract. `-hardlinks` also
opens ordinary files to report those whose hard-link count exceeds one.
Name-surrogate reparse points are inventoried but never followed below the root.

## Results

Returns a dict with `root`, `links`, `multilinked`, `entered`, `dirs`, `files`,
`errors`, `pruned`, `depthlimited`, and `maxdepth`. Reparse rows describe path,
type, target when available, and tag. `multilinked` reports physical files with
shared storage. `entered` contains the non-name-surrogate reparse directories
whose traversal reached directory enumeration. Its rows contain `path`, `tag`,
`surrogate`, and action `descended`; a directory stopped by `-depth`, `-prune`,
an open failure, or an initial enumeration failure is not entered. Any later
partial-enumeration failure remains visible in `errors`.

## Errors

Raised codes are `DIRS badvalue`, `DIRS notfound`, `DIRS oserror`, and
`DIRS usage`. Per-entry inspection failures are disclosed in `errors` where the
walk can continue.

## Lifetime and timeouts

The survey is synchronous and has no timeout. All temporary filesystem handles
are closed before return.

## Examples

```tcl
set report [links C:/work -hardlinks -prune {.git cache}]
foreach row [dict get $report links] {
    puts "[dict get $row type]: [dict get $row path]"
}
```

## Constraints

`-hardlinks` costs an additional handle query per file. The result is a
time-varying snapshot; always inspect the completeness fields and `errors`.

## See also

`machteld/command/dirs`, `machteld/command/canon`.
