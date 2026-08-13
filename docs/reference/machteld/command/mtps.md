---
id: machteld/command/mtps
type: command
title: mtps
summary: List, inspect, and best-effort terminate machine processes by PID.
commands: mtps, mtps list, mtps info, mtps kill
---

# mtps

## Synopsis

```tcl
mtps list
mtps info pid
mtps kill pid ?-tree?
```

## Arguments and options

`pid` is an integer from 0 through 4,294,967,295. `kill -tree` takes one
process snapshot, finds descendants, and terminates deepest descendants before
the selected root. Without `-tree`, only the one PID is targeted.

## Results

`list` returns process dicts; `info` returns one. Rows contain `pid`, `ppid`,
`name`, `threads`, `access`, `exe`, `mem`, `private`, `cpu`, and `started`.
When access is unavailable, detailed fields are empty rather than misleading
zeroes. CPU is milliseconds and `started` is Unix epoch seconds. `kill -tree`
returns `{killed list failed list}`; each failed row has `pid` and stable code
`denied` or `notfound`. Successful non-tree kill returns the same shape.

## Errors

Raised codes are `MTPS badvalue`, `MTPS denied`, `MTPS notfound`,
`MTPS oserror`, and `MTPS usage`. Tree mode carries descendant failures as data;
non-tree failure to open or terminate its single target is raised.

## Lifetime and timeouts

Enumeration and tree membership use one instantaneous Toolhelp snapshot. No
process handle or ownership is retained, and there is no timeout.

## Examples

```tcl
foreach p [mtps list] {
    if {[dict get $p access]} { puts "[dict get $p pid] [dict get $p exe]" }
}
set report [mtps kill $pid -tree]
```

## Constraints

Machine processes are not Machteld-owned. Processes can exit, fork, or reuse a
PID during the operation. Tree kill is therefore best effort; use `child kill`
for a tree launched by Machteld, where a Job Object supplies exact lifetime
ownership. System PIDs 0 and 4 are refused.

## Subcommands

<a id="list"></a>
### list

#### Synopsis

`mtps list`

#### Arguments and options

No arguments.

#### Results

Returns one disclosure dict per process visible in the system snapshot.

#### Errors

Snapshot/enumeration failure reports `MTPS oserror`.

#### Lifetime and timeouts

All process query handles close before return.

#### Examples

`set all [mtps list]`

#### Constraints

Inaccessible process details are empty while `access` is `0`.

#### See also

`machteld/command/mtps#info`.

<a id="info"></a>
### info

#### Synopsis

`mtps info pid`

#### Arguments and options

Takes exactly one PID.

#### Results

Returns the same row shape as `list`.

#### Errors

An absent PID reports `MTPS notfound`; invalid PID reports `badvalue`.

#### Lifetime and timeouts

Snapshot query only.

#### Examples

`set row [mtps info 4812]`

#### Constraints

The row may already be stale when returned.

#### See also

`machteld/command/mtps#list`.

<a id="kill"></a>
### kill

#### Synopsis

`mtps kill pid ?-tree?`

#### Arguments and options

`-tree` enables snapshot-based descendant discovery and best-effort disclosure.

#### Results

Returns lists `killed` and `failed`; descendant failures are data in tree mode.

#### Errors

Non-tree absence/denial is raised. Snapshot/allocation failure and forbidden
system processes are raised with the documented domain codes.

#### Lifetime and timeouts

No ownership survives return.

#### Examples

`dict get [mtps kill $pid -tree] failed`

#### Constraints

Descendants born after the snapshot can escape and PID reuse can race the call.

#### See also

`machteld/command/child#kill`.

## See also

`machteld/command/child`, `machteld/command/run`.
