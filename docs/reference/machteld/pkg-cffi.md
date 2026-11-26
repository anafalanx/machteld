---
id: machteld/package/cffi
type: package
title: Synchronous Windows DLL calls
summary: Call Windows functions from trusted Tcl using the statically linked cffi 2.0.3 and libffi backend.
commands: cffi, package require cffi, ::cffi::Wrapper, cffi::Wrapper
---

# Synchronous Windows DLL calls

## Usage

`package require -exact cffi 2.0.3` loads the upstream `::cffi` commands in a trusted interpreter. Pass a bare system DLL name to search System32, or an absolute path to the application's DLL. For an absolute path, dependent DLLs are resolved from its directory and System32. Relative paths, the current directory and PATH cannot supply a private dependency.

```tcl
package require -exact cffi 2.0.3
set dll [cffi::Wrapper new kernel32.dll]
try {
    $dll function GetCurrentProcessId uint {}
    try {puts [GetCurrentProcessId]} finally {rename GetCurrentProcessId {}}
} finally {$dll destroy}
```

The bound command returns the native value converted according to the declaration. A bound command keeps its module loaded even if the wrapper is destroyed. Removing the last owner permits the module to unload.

## Types, errors and lifetime

Match the exported function's exact calling convention, argument directions, integer widths and return type. For Windows text choose the wide `W` API and UTF-16 types. Invalid UTF-16 text raises an error. Keep binary values as bytes. Follow the native API's buffer, handle and allocator ownership rules. A mistaken declaration can terminate the process.

The caller waits for the function. A supervised process can isolate a slow or failing call and apply a deadline. A worker requires the package and declares its own functions. The bundled build supports synchronous native calls. Native-to-Tcl callbacks, the upstream debugging sandbox, and loading the package in a safe interpreter are unavailable. Errors from cffi keep their upstream error codes.

## Offline manuals

Use `docs get cffi/manual/intro` to start, `docs get cffi/manual/commands` for declarations and command syntax, `docs get cffi/manual/concepts` for ownership and types, and `docs get cffi/manual/cookbook` for examples. `docs get cffi/license` retrieves the package license.

Use a qualified name for one declaration. These lookups return just its signature, parameters and upstream explanation.

```tcl
docs get {cffi::pointer address}
docs get {cffi::Wrapper function}
docs get {cffi::Struct new}
docs get {STRUCTOBJ new}
```

`cffi::Struct new` constructs a type. The `new` method on a resulting struct object allocates a native value. Use the object spelling from the manual (such as `STRUCTOBJ new`) to retrieve an instance method.
