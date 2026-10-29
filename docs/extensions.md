---
type: guide
title: External libraries
description: Explicit Tcl extension loading, trusted native code, and manual deployment policy.
tags: [machteld, extensions, tcl, packages, deployment]
---

# External libraries

A Machteld program can explicitly load compatible binary Tcl extensions and
script packages beyond the built-in palette. Dependency selection and deployment
remain the application's responsibility; there is no plugin manager or automatic
resolver. The working example is `examples/external-extension`, whose small
Tcl-stubs DLL is tested in both console and GUI-subsystem wrappers.

External code is fully trusted. A loaded DLL runs inside the host with the
user's permissions and can crash or compromise it. Script packages run ordinary
Tcl. Neither the entry declaration, a package name, a hash inventory, nor a
supervised subprocess is a permissions sandbox.

## The mechanics

The host provides Tcl's stubs table despite being statically linked. An extension
must still match the host's x64 architecture, Tcl 9 ABI, and its own native
dependencies. The verified example loads an exact DLL **from disk**, beside the
executable and independently of the current directory:

```tcl
package require machteld 0.22
set bundle [file dirname [info nameofexecutable]]
load [file join $bundle examplemath.dll] Examplemath
puts [::examplemath::add 20 22]
```

This code needs the built example bundle; the DLL is not part of Machteld.
For other reviewed packages, ordinary `auto_path` selects `pkgIndex.tcl`
directories and `::tcl::tm::path add` selects directories of `.tm` modules.
Adding either path permits package-loading Tcl code to execute; it does not
audit that code or install a missing package. Script-only packages may be
selected as wrapped application assets, provided the application configures
their lookup paths.

The Windows loader also resolves a DLL's imports. An absolute filename for the
first extension is not a complete dependency or DLL-search policy. Review and
test the actual import chain, runtime libraries, architecture, licenses, and
loader behavior of each deployed extension; do not rely on an unrelated DLL in
the working directory or a developer's installed environment.

## The precedence rule

Prefer the palette and ordinary Tcl when they already meet the requirement.
An extension should address a concrete gap rather than create a second contract
for the same operation. For example, `store` deliberately exposes key/value
operations, not general SQL. An independently selected `sqlite3` extension would
be a separate binding and deployment choice; it does not unlock an existing
Machteld SQL API or share the `store` command's database handle.

## Delivery policy, not packager enforcement

A self-contained delivered tool should not depend on an undocumented developer
installation. For each dependency, choose and verify one of these dispositions:

- **in the box** — part of the explicitly supported platform, with evidence
  for the actual target configurations;
- **in the folder** — shipped with the program: script packages inside the
  wrapped payload, binary extensions and their DLL chains in a directory
  beside the executable;
- **not in the program** — omit the capability until a reviewed deployment
  meets the intended installation-free delivery policy.

This is an authoring policy, not something `wrap` enforces. It does not inspect
imports, prevent downloads or registry writes, or certify that the program works
on every Windows target. Test a fresh complete deployment without relying on
development-only packages, drivers, credentials, or PATH entries.

## Database scope

Only SQLite through `store` is built in and covered by Machteld's database
contract. TDBC/ODBC, PostgreSQL, MySQL/MariaDB, Office drivers, and a full-SQL Tcl
SQLite binding are not bundled or verified integrations. They require their own
compatibility, authentication, license, and deployment review for a real use
case. The tiny arithmetic extension proves the loading pattern, not any database
binding's availability or suitability. No driver or installed application
should be assumed merely because the target runs Windows.

## What this page does not promise

Dependency selection remains manual. `wrap --manifest` selects named application
files; it does not discover `package require` dependencies, download packages,
resolve transitive DLLs, or provide a `--deps` mode. Possible historical plans in
the roadmap are not implemented contracts.

For a concrete source example, see `examples/external-extension` in the
repository. It builds a tiny Tcl-stubs DLL, explicitly inventories the DLL and
its license beside a wrapped application, and loads that exact disk path. The
application can be started from a different working directory; moving or
removing its declared DLL causes a clear failure, not an implicit search for an
unrelated installed package.

Build a fresh deployment folder containing the complete reviewed set. `wrap`
atomically publishes one executable, not a multi-file deployment transaction.
Do not overwrite an installed DLL chain piecemeal. Include dependency license
notices and any runtime DLLs required by the extension's own compiler; being
linked against Tcl stubs does not eliminate its other dependencies.
