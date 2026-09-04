# machteld

machteld is a compact Windows machine-control runtime: Tcl/Tk 9.0.4 plus a small,
structured command palette currently implemented in Tcl and native C. It ships as
one executable, starts no service, needs no installed Tcl, and keeps Windows
process, ConPTY, filesystem, HTTP, hashing, JSON, and SQLite machinery behind
Tcl-shaped commands.

## 0.20 — clean Tcl/Tk foundation

**[machteld 0.20 is released](https://github.com/anafalanx/machteld/releases/tag/v0.20)**
(2026-09-04; the executable is Authenticode-signed, with its SHA-256 checksum
beside it). Machteld is decisively a Tcl/Tk platform, with C and C++ as its only
admitted native implementation languages. The compute-engine architecture, the
`macht` command, Lua, LPeg, lua-cjson, and the engine-bound column library have
been removed together. There is no compatibility layer or migration path for
those experimental surfaces. This deliberately smaller release is the baseline
for further development.

The existing machine-control palette remains. Its JSON reader stands on a
vendored yyjson 0.12.0 core with a byte-faithful plain mode and a typed mode
that preserves JSON identity through `json value/type/unwrap/get/exists`.
`http -redirect none` stops an authenticated request at the first 3xx, and a
pty child's stdio remains bound to the ConPTY even when the parent's own stdio
is redirected. The commands and their intended composition live in
[the palette page](docs/palette.md).

The bundled Tcl core is 9.0.4 plus the exact upstream correction for
[Tcl ticket d40d8db3](https://core.tcl-lang.org/tcl/tktview/d40d8db3fb), which
preserves executable paths below ACL-restricted directories. The backport,
source hashes, and upstream check-in identity are locked into the local build.
The executable's Windows properties carry exact `0.20` file/product versions
and the repository author/copyright identity; local build paths are scrubbed
from the packaged runtime.

Machteld 0.20 supports 64-bit Windows 11 25H2 (build 26200) and Windows
Server 2025 (build 26100) or newer. Windows 10 and Server 2022/2019 are below
the contracted floor; ARM64 is not a target. ConPTY sets the technical floor
and has existed since Windows 10 1809, so the binary may start below the
contract — but the shipped artifact is x64 and supported only on the releases
named here.

Version 0.20 deliberately has one entry route: a readable UTF-8 program file.
The conventional extension is `.tcl`, but the runtime does not require it. The
file must begin with a literal opt-in command:

```tcl
package require machteld 0.20

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
- Runtime support: `version`, `manifest`, `docs`, `help`, and `wrap`.

Commands live in `::machteld`; the prelude adds that namespace to the global
command path, so small programs can use the bare names shown above. `manifest`
returns the exact verbs, options, subcommands, declared fixed result shapes, and
raised/protocol error codes in the running executable. `docs` searches and reads
the exact Machteld, Tcl 9, and Tk 9 references embedded in every normal host:

```text
machteld.exe --docs status --json
machteld.exe --docs get tcl/command/dict --json
machteld.exe --docs search "channel binary encoding" --limit 10 --json
```

Agents should query this corpus instead of relying on web memory from a
different runtime version. `docs extract` publishes the complete corpus to a
directory for ordinary filesystem search; `help` is a concise human shorthand.

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
subtree, the staged entry is validated, and the output is published atomically.
There is no reduced runtime mode: every wrapped console or GUI tool exposes the
same programmatic Machteld 0.20 machine-control API, including the statically
linked, binary-safe SQLite `store`. Wrapped tools also retain the complete
offline reference corpus; wrapping basekits are not embedded recursively.

Start with [the documentation index](docs/index.md), the concise
[agent bootstrap](docs/reference/machteld/agent.md), and the
[complete Machteld reference](docs/reference/machteld/index.md).

Machteld's own code is licensed under the [Apache License 2.0](LICENSE).
Bundled material retains its own terms, including the verbatim
[Tcl](licenses/Tcl-9.0.4.txt), [Tk](licenses/Tk-9.0.4.txt),
[zlib](licenses/zlib-1.3.2.txt), [LibTomMath](licenses/LibTomMath-1.3.0.txt), and
[yyjson](licenses/yyjson-0.12.0.txt) notices. The statically linked SQLite
amalgamation is public domain. JSONTestSuite is a test-only dependency and
retains [its own license](test/jsontestsuite/LICENSE).
