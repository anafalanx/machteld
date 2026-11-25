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
Tcl-stubs DLL is tested alongside a relocated application archive.

External code is fully trusted. A loaded DLL runs inside the host with the
user's permissions and can crash or compromise it. Script packages run ordinary
Tcl. Neither the entry declaration, a package name, a hash inventory, nor a
supervised subprocess is a permissions sandbox.

## The mechanics

The host provides Tcl's stubs table despite being statically linked. An extension
must still match the host's x64 architecture, Tcl 9 ABI, and its own native
dependencies. The verified example loads an exact DLL **from disk**, beside the
application archive, independently of the current directory:

```tcl
package require machteld 30-
set bundle [file dirname [file normalize $argv0]]
load [file join $bundle examplemath.dll] Examplemath
puts [::examplemath::add 20 22]
```

This code needs the built example bundle; the DLL is not part of Machteld.
For other reviewed packages, ordinary `auto_path` selects `pkgIndex.tcl`
directories and `::tcl::tm::path add` selects directories of `.tm` modules.
Adding either path permits package-loading Tcl code to execute; it does not
audit that code or install a missing package. Script-only packages may be
selected as application archive members, provided the application configures
their lookup paths.

The Windows loader also resolves a DLL's imports. An absolute filename for the
first extension is not a complete dependency or DLL-search policy. Review and
test the actual import chain, runtime libraries, architecture, licenses, and
loader behavior of each deployed extension; do not rely on an unrelated DLL in
the working directory or a developer's installed environment.

## The precedence rule

Prefer the palette and ordinary Tcl when they already meet the requirement.
The built-in `store` covers key/value operations. For general SQL, load the
embedded Tcl binding with `package require sqlite3` and open a connection.
Both interfaces use the same SQLite library.

## Delivery policy, not packager enforcement

A self-contained delivered tool should not depend on an undocumented developer
installation. For each dependency, choose and verify one of these dispositions:

- **in the box** — part of the explicitly supported platform, with evidence
  for the actual target configurations;
- **in the folder** — shipped with the program: script packages inside the
  archive, binary extensions and their DLL chains in a directory
  beside the archive;
- **not in the program** — omit the capability until a reviewed deployment
  meets the intended installation-free delivery policy.

The application author reviews imports and provisions the DLLs required on
the supported Windows targets. Test a fresh complete deployment without relying on
development-only packages, drivers, credentials, or PATH entries.

## Database scope

The [database contract](contract.md) covers both SQLite interfaces in
Machteld. TDBC/ODBC, PostgreSQL, MySQL/MariaDB and Office drivers require their own
compatibility, authentication, license, and deployment review for a real use
case. The tiny arithmetic extension proves the loading pattern, not any database
binding's availability or suitability. No driver or installed application
should be assumed merely because the target runs Windows.

## Distributing a native dependency

Project manifests select the files that `pack` places in the application
archive. Ship native extensions as reviewed Windows files. In
`examples/external-extension` the Tcl entry loads the adjacent DLL by absolute
path, and `ship.dict` lists the archive, runtime, DLL and notices. Move the
folder and run it from an unrelated working directory to check the deployment.

Publish a new complete folder when changing a DLL chain. The atomic update
of an application archive applies only to that archive. A stubs build can
still need additional native libraries or the compiler's runtime.
