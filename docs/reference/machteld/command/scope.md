---
id: machteld/command/scope
type: command
title: scope
summary: Evaluate a Tcl body and close every child created inside it on every exit path.
commands: scope
---

# scope

## Synopsis

```tcl
scope body
```

## Arguments and options

`body` is evaluated one level up in the caller's scope. There are no options.
Before evaluation, `scope` snapshots the interpreter's child registry.

## Results

Returns the body's result with its original Tcl return code and options. A
normal result, `return`, `break`, `continue`, and error all preserve their
semantics after cleanup.

## Errors

The body's error propagates unchanged. Cleanup is best effort so a child-close
failure does not replace the body's original completion. Wrong arity is a Tcl
error.

## Lifetime and timeouts

After body completion, every `child` token not present in the initial snapshot
is closed, terminating a still-running tree. Scopes nest naturally because each
one only owns children born after its own snapshot. `scope` adds no timeout.

## Examples

```tcl
set answer [scope {
    set server [child start -- server.exe]
    run -timeout 30s -- client.exe
}]
```

## Constraints

The boundary covers `child` handles created in the same interpreter. It does
not automatically close PTYs, watches, pools, files, stores, or detached
processes. Use their explicit cleanup operations.

## See also

`machteld/command/child`, `machteld/command/detach`,
`machteld/guide/execution-model`.
