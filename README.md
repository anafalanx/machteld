# machteld

machteld is a compact Windows machine-control runtime: Tcl 9 plus a small,
structured command palette implemented in C and Tcl. It ships as one executable,
starts no service, needs no installed Tcl, and keeps Windows process, ConPTY,
filesystem, HTTP, hashing, JSON, and SQLite machinery behind Tcl-shaped commands.

The 0.4.0 release target is 64-bit Windows 10 version 1809 or newer (including
Windows 11 and corresponding Windows Server releases). ConPTY sets that floor;
the shipped artifact is x64, not a claim to run on every historical Windows box.

Version 0.4.0 deliberately has one entry route: a readable UTF-8 program file.
The conventional extension is `.tcl`, but the runtime does not require it. The file must
begin with a literal opt-in command:

```tcl
package require machteld 0.4.0

set result [run -timeout 30s -- git status --short]
puts [dict get $result out]
```

Run it directly:

```text
machteld.exe app.tcl argument ...
```

The entry check is parsed before the file is evaluated. `package require
machteld`, an optional literal version, and `package require -exact machteld
<version>` are accepted. A generic Tcl script is refused: using this runtime is
an explicit dependency, not an inference from a filename.

## The palette

- Process control: supervised `run`, `child`, `wait`, and `scope`; independent
  `detach`.
- Interactive programs: `pty spawn/send/read/expect/strip/close` over ConPTY.
- Machine observation: `watch`, `mtps`, `dirs`, `links`, and `canon`.
- Data and network: `store`, `json`, `hash`, and `http`.
- Tool support: `cli`, `log`, `worker`, `pool`, and `pmap`.
- Runtime support: `version`, `manifest`, `help`, and `wrap`.

Commands live in `::machteld`; the prelude adds that namespace to the global
command path, so small programs can use the bare names shown above. `manifest`
returns the exact verbs, options, subcommands, declared fixed result shapes, and
raised/protocol error codes in the running executable. `help` reads bundled
documentation when the distribution host carries it.

Machteld failures use Tcl's structured error code, while a supervised program's
timeout is a normal result state:

```tcl
set result [run -timeout 2s -- slow.exe]
if {[dict get $result status] eq "timeout"} {
    puts stderr "slow.exe exceeded its deadline"
}
```

Durations always carry units: `500ms`, `30s`, `5m`, or `2h`.

## Standalone tools

`wrap` turns an opted-in program file, or a directory containing one, into a
standalone console or GUI executable without a compiler:

```text
machteld.exe wrap app.tcl -o app.exe
machteld.exe wrap appdir -o app.exe --entry src/start.tcl --gui
```

A directory defaults to `main.tcl`. Hidden assets are included under an `app/`
subtree, the staged entry is validated, and the output is published atomically. There is no
reduced runtime mode: every wrapped console or GUI tool exposes the same
programmatic Machteld 0.4.0 machine-control API, including the statically linked,
binary-safe SQLite `store`. Distribution-only documentation and wrapping
basekits are not embedded recursively in tools.

Start with [the documentation index](docs/index.md), then use
[the palette](docs/palette.md) as the command reference and
[the contract](docs/contract.md) for stable conventions.

Machteld's own code is licensed under the [Apache License 2.0](LICENSE).
Bundled material retains its own terms, including the verbatim
[Tcl](licenses/Tcl-9.0.4.txt) and [Tk](licenses/Tk-9.0.4.txt) notices and the
[JSONTestSuite license](test/jsontestsuite/LICENSE).
