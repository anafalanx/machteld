# machteld

machteld is a compact Windows runtime for Tcl/Tk 9 programs. It is strongest
at what tools do: supervised processes and terminals, files, HTTP, JSON,
hashing and SQLite, in one executable that installs nothing. That executable
is Tcl/Tk 9.0.4 plus a small command palette implemented in Tcl and native C,
with C/C++ as the admitted native languages; it starts no service and needs no
installed Tcl. machteld is Vincent Vercauteren's own runtime and serves tools
first; other people's adoption is welcome, but is not the design target. There
are no compute engines, `macht`, or Lua. Development environments built with
machteld live in their own repositories on the machines that use them; this
repository holds the runtime only.

## 30 — in development

**0.30 is the next public release after signed 0.21.** Development starts
from the unpublished 0.22 candidate. The CLI and Tcl package in this checkout both report `30`.
The build tools use the signed executable at `dist/0.21/machteld.exe`.
[Signed 0.21 release](https://github.com/anafalanx/machteld/releases/tag/v0.21) ·
[Build guide](BUILDING.md)

The development baseline includes the Beta 1 features. Tk applications can run
cancellable jobs and SQL queries in supervised workers. Workers started
from a running archive keep using its version after an update. The runtime
also supports atomic file replacement, process-owned locks, attended child
windows and clipboard ownership queries. The exact Beta 1 revision passed
72 release and desktop steps. [Beta 1 results and checklist](docs/releases/0.22-beta.1.md)

| Behavior | Signed 0.21 release | Unpublished 22 baseline |
| --- | --- | --- |
| Reference corpus in wrapped tools | Always included | Omitted unless `--with-docs` |
| Explicit wrap inventory and application branding | Not available | `--manifest`, `--plan`, optional application name, version and icon |
| Application archives | Direct Tcl files and wrapped tools | Also runs and creates `.machteld` archives for the shared runtime |
| Database access | Key/value `store` | `store` and the built-in Tcl `sqlite3` package |
| Default pool attempts per job | Three | One; retries require explicit opt-in |
| Transport/lifecycle hardening and native stress checks | Original release baseline | Later stabilization fixes and tests |

Before signing 0.30, the build PC and hosted Windows CI must produce
byte-identical clean unsigned executables from the same revision and
locked inputs. The runtime and packaged examples must pass acceptance,
including attended checks of user-visible behavior. The owner signs a copy,
the gate checks those signed bytes, and the owner decides when to publish.

The rest of this README and the current guides describe **30**, unless
explicitly marked as history. Different builds can share that version:
incremental builds embed `build-info.dict` with source/input and reference
identities; clean reconstruction omits that development-only record. Compare
artifact hashes and verification receipts, and query `manifest` and the
documentation in the executable you actually use.

## The plan and the commentary

The roadmap records the approved 0.30 capabilities. The release plan sets
the implementation order and acceptance gates for moving directly from
signed 0.21 to 0.30. [Roadmap](docs/roadmap.md) ·
[Implementation and release gates in the release plan](plan-machteld22.md)

Agents: what you find in the runtime while you use it or work on it, good or
bad, goes in [commentary.md](commentary.md), as an entry of your own at its
end. The owner reads it when the next machteld is planned.

## Scope and trust

Programs and extensions are **trusted local code**, with the launching user's
permissions. Job Objects supervise process lifetime and resource limits; they
are not a security sandbox. `-dir` is a working directory, not filesystem
confinement. An environment overlay does not isolate credentials. Archived
applications retain full runtime authority. Entry opt-in is a dependency
declaration, not an authorization boundary.

The support contract is x64 Windows 11 25H2 (build 26200) and Windows Server
2025 (build 26100), or newer. Windows 10, Server 2022/2019, and ARM64 are not
targets. Stabilization checks ran on Windows 11 Pro build 26200, and Beta 1
passed its Windows Server 2025 acceptance run. Record fresh results for each
0.30 release candidate on the supported targets. Lower-level ConPTY availability on
older Windows does not extend the support contract.

Use `store` for key/value data and `package require sqlite3` for SQL queries,
transactions and backups. Both use the same embedded SQLite engine, including
in packaged applications. Database calls are synchronous. External extensions are
provisioned manually. See [database access](docs/contract.md),
[execution](docs/execution-model.md), and [external libraries](docs/extensions.md).

## A first program

Save this UTF-8 file as `app.tcl`. Its first executable command explicitly
opts into Machteld; the `.tcl` extension is conventional, not required.

<!-- machteld-example: app -->
```tcl
package require machteld 30-
puts "Hello, [lindex $argv 0]!"
```

<!-- machteld-example: direct -->
```text
machteld.exe app.tcl world
```

This prints `Hello, world!`. The entry parser accepts `package require
machteld`, an optional literal version, or `package require -exact machteld
<version>`. Generic Tcl scripts without that declaration are refused.

Tcl treats each whole-number runtime version as a major version.
An existing entry with the requirement `22-` accepts 30. An entry with
`22-30` fails on 30 because Tcl excludes the upper bound. Use
`package require -exact machteld 30` to pin an entry to this version.

For a supervised child, save the following as `supervise.tcl` beside `app.tcl`
and run it with the distribution executable. This is a direct-script example:
an archived controller can start the same application generation using
`app launch`, as demonstrated by the
[project inspector](examples/project-inspector/README.md).

<!-- machteld-example: supervise -->
```tcl
package require machteld 30-
set result [run -timeout 5s -- [info nameofexecutable] \
    [file join [file dirname [info script]] app.tcl] world]
if {[dict get $result status] ne "ok" || [dict get $result exit] != 0} {
    error "child did not succeed: $result"
}
# This particular child emits UTF-8. Other programs may use another encoding.
puts -nonewline [encoding convertfrom -profile strict utf-8 [dict get $result out]]
```

<!-- machteld-example: supervised -->
```text
machteld.exe supervise.tcl
```

`run` returns captured **bytes**, not already-decoded text. A deadline expiring
is a normal `status timeout` result; launch/option errors raise structured
Tcl error codes. Check both status and exit code. Durations carry units, such
as `500ms`, `30s`, `5m`, or `2h`. Captured output is bounded and reports drops;
use explicitly drained channels or files for larger transfers, not an
ever-growing Tcl result. `run` and other synchronous calls block Tk callbacks;
use event-driven `child -channels` composition for responsive tools.

## The palette and its reference

- Process control: supervised `run`, `child`, `wait`, and `scope`; independent
  `detach`.
- Interactive programs: `pty spawn/send/read/expect/strip/close` over ConPTY.
- Machine observation: `watch`, `mtps`, `dirs`, `links`, and `canon`.
- Data and network: `store`, `json`, `hash`, and `http`.
- Tool support: `cli`, `log`, `worker`, `pool`, and `pmap`.
- Application support: `app launch` for workers, `publish` for atomic file replacement, and `lock` for exclusive use of a resource across processes.
- Runtime support: `version`, `manifest`, `docs`, and `help`.

Commands live in `::machteld`; the prelude adds it to the global command path.
`manifest` describes the running executable's verbs, options, fixed result
shapes, and errors. `docs` reads its embedded Machteld, Tcl, Tk and cffi corpus:

<!-- machteld-example: docs -->
```text
machteld.exe --docs status --json
machteld.exe --docs get tcl/command/dict --json
machteld.exe --docs search "channel binary encoding" --limit 10 --json
```

Use these references instead of assuming another runtime's API. `docs extract`
publishes the corpus for filesystem search; `help` is a concise shorthand.
Plain JSON uses Tcl representations and cannot preserve every JSON distinction;
use typed JSON when string/number, boolean, null, and container identity matter.
The [palette](docs/palette.md) and [exact reference](docs/reference/machteld/index.md)
describe composition and limits, including retries and cancellation.

## Application archives

To distribute an application to someone who already has Machteld 30, put its
opted-in `main.tcl` and assets in a staging directory. The full host can pack
that tree into a plain ZIP and run it with the usual program arguments.

<!-- machteld-example: archive -->
```text
machteld.exe pack myapp -o myapp.machteld
machteld.exe myapp.machteld world
```

The archive carries the application files. The host supplies Tcl/Tk and the
runtime. A single-file program can be packed directly with
`machteld.exe pack app.tcl -o app.machteld`. [Packaging guide](docs/packaging.md)

For a project with a named entry and selected files, use
`machteld.exe pack app.dict -o app.machteld`. The runtime verifies the file list,
lengths and hashes before running the entry. The packaged examples demonstrate
worker roles and the adjacent DLL layout. [Project inspector](examples/project-inspector/README.md) ·
[External extension](examples/external-extension/README.md)

## Building and testing

Unsigned candidates can run on the build PC and in a hosted Windows CI job.
Unsigned executables stay inside the CI job. The owner
signs release executables on the build PC. [Build guide](BUILDING.md)

Every build and test tool is a Tcl program that runs on the build runtime,
`dist/0.21/machteld.exe`, the signed 0.21 release, and finds MSYS2 through
`--msys` (which the development loop does not take), `MSYS2_ROOT`, or
`C:\msys64`. `tools/bootstrap.tcl` provisions the pinned build dependencies;
`tools/dev.tcl build` writes the incremental executable to
`out/dev/machteld.exe`. A standalone clean build with `tools/release.tcl`
defaults to `out/candidate/machteld.exe`. The release gate,
`tools/gate.tcl`, builds `out/machteld.exe` and runs every test group on it;
`--skip-build` tests the executable as it is. `--group fast`,
`integration`, `packaging`, `native-validation`, or `reference-generator`,
repeatable, runs just those groups and never builds; `fast` needs no MSYS2.
With `--skip-build` or `--group`, `--runtime <path>` tests another executable
than `out/machteld.exe`, as it is; the gate refuses `--runtime` when it would
build, because its build would replace that file. A run that tests an
executable names it by version and SHA-256 and fails if it changes.

`reference-generator` checks two independent cold conversions byte for byte.
`native-validation` adds bounded lifetime and worker-scaling tests, the native
drivers built with undefined-behavior traps, after their negative controls,
and the full analysis of `tools/native-analysis.tcl`, GCC's analyzer and the
sanitizer probes among it; [its guide](docs/native-validation.md) records
coverage gaps. Off by default, each behind its own option: public TLS and
interactive console checks (`--public-tls`, `--interactive-pty`), and the real
Tk windows of `--interactive-gui`. A gate run signs nothing and publishes no
release; its build goes to `out/machteld.exe` only.

Unchanged development builds reuse each reference generation by content; a
documentation edit generates the reference again, in about a minute, and Tcl
implementation-only edits repackage. Cache hits verify content and
inventories, not timestamps. The version check rejects recognizable stale
current-runtime claims and malformed historical annotations; genuine release
history keeps its original numbers. It is a guardrail, not a substitute for
reviewing prose against behavior. The fast and packaging groups execute the
marked README examples themselves.

The bundled Tcl is 9.0.4 with the pinned upstream ACL-path correction for
[ticket d40d8db3](https://core.tcl-lang.org/tcl/tktview/d40d8db3fb). Dependency
versions, source hashes, and the backport identity are recorded in
[the lock](tools/dependencies.lock.json). Machteld's Windows file/product
version is exactly `30`, and 30.0.0.0 as Windows' fixed version; its author,
publisher, and copyright holder are Vincent Vercauteren. Build paths are
scrubbed from the packaged runtime.

Start with [the documentation index](docs/index.md) or the
[agent bootstrap](docs/reference/machteld/agent.md).

Machteld's own code is licensed under the [Apache License 2.0](LICENSE).
Bundled material retains its own terms, including the verbatim
[Tcl](licenses/Tcl-9.0.4.txt), [Tk](licenses/Tk-9.0.4.txt),
[zlib](licenses/zlib-1.3.2.txt), [LibTomMath](licenses/LibTomMath-1.3.0.txt),
[yyjson](licenses/yyjson-0.12.0.txt) and [xxHash](licenses/xxHash-0.8.3.txt) notices. The foreign-function interface includes
[cffi](licenses/cffi-2.0.3.txt), [Tclh](licenses/tclh-6afd306.txt) and
[libffi](licenses/libffi-3.5.2.txt). The SQLite amalgamation is public domain.
The encoding detector adapts code from [Els](licenses/Els-MIT.txt). The Windows
application catalog and icon conversion adapt code from [Ann](licenses/Ann-MIT.txt).
Windows network diagnostics adapt code from [Airwave](licenses/Airwave-MIT.txt).
UDP address parsing adapts code from [Lunar](licenses/Lunar-MIT.txt).
JSONTestSuite is test-only and retains
[its own license](test/jsontestsuite/LICENSE).
