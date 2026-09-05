---
id: machteld/command/dirs
type: command
title: dirs
summary: Walk a Windows directory tree deterministically without following name-surrogate links.
commands: dirs
---

# dirs

## Synopsis

```tcl
dirs root ?-depth nonnegativeInteger? ?-prune patterns?
```

## Arguments and options

- `root` must resolve to a directory. A reparse-point root itself is entered
  because the caller named it; name-surrogate descendants are not followed.
- `-depth n` bounds descent. Omitting it is unlimited; `0` emits only the root.
- `-prune patterns` takes a Tcl list of case-insensitive `string match` patterns
  applied to each entry's base name. A matched directory is not entered.

## Results

Returns a dict with `root`, ordered `paths`, directory count `dirs`, link
decisions `links`, nonfatal `errors`, and the completeness facts `pruned`,
`depthlimited`, and `maxdepth`. Link rows disclose path, reparse tag, whether it
is a name surrogate, and the action taken. Error rows contain path, Win32 code,
and reason.

## Errors

Raised codes are `DIRS badvalue`, `DIRS notfound`, `DIRS oserror`, and
`DIRS usage`. A root that does not exist is `notfound`; a root that exists but
may not be opened is `oserror`, so denied is never mistaken for absent. Errors
encountered below a valid root are normally disclosed in the result's `errors`
list instead of aborting the whole survey.

## Lifetime and timeouts

The walk is synchronous, retains no handles after return, and has no timeout.

## Examples

```tcl
set survey [dirs C:/src -depth 5 -prune {.git node_modules out}]
if {[dict get $survey errors] ne {}} {
    puts stderr "tree was not completely readable"
}
foreach path [dict get $survey paths] { puts $path }
```

## Constraints

The returned answer is a snapshot assembled during traversal, not an atomic
filesystem transaction. Inspect `errors`, `pruned`, and `depthlimited` before
treating it as complete. Prune patterns match names, not full paths.

## See also

`machteld/command/links`, `machteld/command/canon`,
`machteld/command/watch`.
