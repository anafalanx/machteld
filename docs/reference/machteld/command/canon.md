---
id: machteld/command/canon
type: command
title: canon
summary: Resolve a Windows path to its final target and stable volume/file identity.
commands: canon
---

# canon

## Synopsis

```tcl
canon path
```

## Arguments and options

`path` names an existing file or directory. The command follows reparse points
in the final component. There are no options.

## Results

Returns a dict with:

- `path`: the normalized final DOS or UNC path;
- `volume`: a fixed-width hexadecimal volume identity;
- `file`: a fixed-width hexadecimal file identity on that volume;
- `kind`: `file` or `directory`;
- `links`: the filesystem hard-link count.

Compare `{volume file}` pairs as opaque strings when physical identity matters.

## Errors

Raised codes are `DIRS badvalue`, `DIRS dangling`, `DIRS notfound`, and
`DIRS oserror`, plus Tcl wrong-arity errors. `dangling` means the path name
exists as a reparse point but its target cannot be resolved.

## Lifetime and timeouts

The command opens the target only for the duration of the query and retains no
handle. It has no timeout.

## Examples

```tcl
set a [canon C:/work/current]
set b [canon C:/releases/active]
set same [expr {[dict get $a volume] eq [dict get $b volume] &&
                [dict get $a file] eq [dict get $b file]}]
```

## Constraints

Identity is a filesystem fact at the instant of the call; a path can be replaced
afterward. `canon` follows the target and therefore is not a link-inventory API.

## See also

`machteld/command/links`, `machteld/command/dirs`.
