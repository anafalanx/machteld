---
type: guide
title: External libraries
description: How a Machteld program uses Tcl extensions, the covenant that governs shipping them, and when a port beats a dependency.
tags: [machteld, extensions, tcl, packages, deployment, porting]
---

# External libraries

A Machteld program can use binary Tcl extensions and script packages beyond
the built-in palette. This page records the mechanics that work today, the
precedence rule that keeps the palette honest, the deployment covenant
that governs what a shipped program may depend on — and the fourth way,
which is to take no dependency at all.

## The mechanics

The Machteld host is statically linked, and that is no obstacle: Tcl
extensions are built against the stubs table, which the host provides like
any other interp. Extension DLLs load **from disk**; script-only packages
and `.tm` modules resolve through their own two mechanisms:

```tcl
package require machteld 0.11.0
lappend auto_path {C:/path/to/tcl9/lib}              ;# pkgIndex packages (DLLs)
::tcl::tm::path add {C:/path/to/tcl9/lib/tcl9/9.0}   ;# .tm modules
package require tdbc::odbc
```

Two mechanisms, deliberately: `auto_path` finds `pkgIndex.tcl` directories;
Tcl modules are single `.tm` files found only through `tm::path`. A
dependent DLL chain (a client library and its siblings) must be resolvable
by the loader — keep a chain together in one directory on the DLL search
path.

## The precedence rule

**Palette first, extension second.** An extension is for capabilities the
palette lacks, never an alternative to ones it curates. The canonical
example: `store` is deliberately a narrow key/value API over the statically
linked SQLite — *not* an SQL surface. Loading the `sqlite3` extension adds
a second, independent SQLite to the process for its SQL surface; that can
be a deliberate, informed choice, but it duplicates an organ the host
already carries and steps around a contract decision. Know which one you
are making.

## The covenant

A wrapped Machteld program **just works** on its target machine. Every
dependency is one of exactly three things:

- **in the box** — guaranteed present on the program's Windows floor and
  recorded as such with evidence (assume nothing: ODBC drivers for Excel
  and Access, for instance, arrive with Office, not Windows);
- **in the folder** — shipped with the program: script packages inside the
  wrapped payload, binary extensions and their DLL chains in a directory
  beside the executable;
- **not in the program** — refused. There is no fourth category; "ask the
  user to install a driver first" is not a state a shipped program may be
  in.

One consequence worth internalizing: an ODBC *driver* cannot ship in a
folder — drivers require registry installation — so ODBC is only usable
where Windows itself provides the driver. Direct client libraries that
load from a directory (libpq-style) satisfy the covenant naturally and are
preferred for shipped programs.

## Databases, concretely

- **SQLite** — in every host, statically, behind `store`; the `sqlite3`
  extension adds a full SQL surface when informed use calls for it.
- **SQL Server** — reachable through `tdbc::odbc` and the in-box legacy
  "SQL Server" driver; it speaks an old TDS dialect, and strictly
  configured modern servers may refuse it.
- **PostgreSQL** — `tdbc::postgres` plus a shipped `libpq` chain
  (BSD-family licensed, copy-distributable, no installer).
- **MySQL/MariaDB** — `tdbc::mysql` plus the LGPL MariaDB Connector/C as
  a separately shipped DLL with its license text beside it.
- **Excel files** — prefer reading `.xlsx` directly (it is zipped XML)
  over the Office-installed ODBC driver, which the covenant cannot count
  on.
- **Access `.accdb`** — refused: no covenant-compliant route exists.

## The port, before the dependency

For a capability of bounded size whose problem is frozen — a format, an
algorithm, a calculation — the strongest way to use an external library is
to take its **contract**, not its code. Port the behavior into plain Tcl
and keep the original as the oracle:

- **The original's behavior is the contract.** During development, run the
  reference implementation beside the port and differential-test them:
  same inputs, same results, same inputs refused. Disagreements are
  settled by the oracle, never by taste — and the oracle's corrections are
  the pattern's whole value, because they land before a line ships. The
  fixtures carry their provenance (oracle name, version, date) into the
  suite; the oracle itself lives and dies at development time and ships
  nowhere.
- **Port the behavior, never translate the source.** A translation
  inherits the original's license; an independent implementation against
  the observed contract is Machteld's own. The port therefore carries no
  notice obligation, no DLL chain, and no upstream decay rate — if the
  problem does not change, the solution does not have to change either.
- **State every claim exactly.** Where the port matches the oracle, say so
  with name and version. Where it deviates, refuse by name or write the
  deviation down. Equivalence claims come in strengths — byte-identity is
  not round-trip fidelity — and the suite holds precisely the claim that
  was made, never a stronger one implied.

The paid-for exemplar is `csv`: Text::CSV_XS, the CPAN reference
implementation, was installed beside the work and differential-tested
against `tcl/csv.tcl` — edge fixtures and seeded round-trip fuzz agreeing
byte for byte — before the contract was written into `test/csv_test.tcl`
and the command reference. The oracle overruled the author's reading of
the format several times before any code was committed (a bare CR
terminates a record; an empty line is one empty field); a port without
its oracle is a guess with confidence.

The rule of thumb: below a few thousand lines of frozen problem, the port
beats the dependency. Above that, the covenant governs — and the
palette-first rule governs both.

## What this page does not promise

Automatic dependency resolution at wrap time — classifying a program's
requires, folding script packages into the payload, staging DLL chains
beside the output with a hashed manifest, and a `--deps` verification mode
— is contracted direction, not present behavior; see the roadmap. Today,
the program author places extension files and the two path commands
deliberately, which has the virtue of being exactly as reliable as it
looks.
