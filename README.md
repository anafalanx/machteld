# machteld

machteld is Vincent Vercauteren's Windows machine-control platform: Tcl/Tk
9.0.4 plus a small command palette implemented in Tcl and native C, with C/C++
as the admitted native languages. It ships as one executable, starts no
service, and needs no installed Tcl. Other people's adoption is welcome, but
is not the design target. There are no compute engines, `macht`, or Lua.

## 0.22 candidate — unsigned, release gate in progress

The signed [0.21 release](https://github.com/anafalanx/machteld/releases/tag/v0.21)
is preserved in `dist/0.21`; its [release notes](dist/0.21/RELEASE_NOTES.md)
describe that artifact, not everything now in this checkout. The current
candidate reports runtime version **0.22** and includes later stabilization:

| Behavior | Signed 0.21 release | Unsigned 0.22 candidate |
| --- | --- | --- |
| Reference corpus in wrapped tools | Always included | Omitted unless `--with-docs` |
| Explicit wrap inventory and application branding | Not available | `--manifest`, `--plan`, metadata and icons |
| Default pool attempts per job | Three | One; retries require explicit opt-in |
| Transport/lifecycle hardening and native stress checks | Original release baseline | Later stabilization fixes and tests |

Step 12 is in progress: the candidate must pass clean reconstruction, artifact
comparison, and the acceptance matrix before it is considered ready. It is
**not a released or signed artifact**; signing and publication are not authorized
by this candidate gate, and the signed release remains untouched.

The rest of this README and the current guides describe the **0.22 candidate**,
unless explicitly marked as history. Different candidate builds can share that
version: incremental builds embed `build-info.dict` with source/input and
reference identities; clean reconstruction omits that development-only record.
Compare artifact hashes and verification receipts, and query `manifest` and the
documentation in the executable you actually use. See the [roadmap](docs/roadmap.md)
for history and the remaining release gate.

## Scope and trust

Programs and extensions are **trusted local code**, with the launching user's
permissions. Job Objects supervise process lifetime and resource limits; they
are not a security sandbox. `-dir` is a working directory, not filesystem
confinement. An environment overlay does not isolate credentials. Wrapped
applications retain full runtime authority. Entry opt-in is a dependency
declaration, not an authorization boundary.

The support contract is x64 Windows 11 25H2 (build 26200) and Windows Server
2025 (build 26100), or newer. Windows 10, Server 2022/2019, and ARM64 are not
targets. Current stabilization checks ran on Windows 11 Pro build 26200; that
is not a fresh Server acceptance result. Lower-level ConPTY availability on
older Windows does not extend the support contract.

Machteld deliberately retains a narrow key/value `store`, synchronous commands,
and manually provisioned external extensions. It is not a general database or
an automatic dependency manager. See [execution](docs/execution-model.md),
[the contract](docs/contract.md), and [external libraries](docs/extensions.md).

## A first program

Save this UTF-8 file as `app.tcl`. Its first executable command explicitly
opts into Machteld; the `.tcl` extension is conventional, not required.

<!-- machteld-example: app -->
```tcl
package require machteld 0.22
puts "Hello, [lindex $argv 0]!"
```

<!-- machteld-example: direct -->
```text
machteld.exe app.tcl world
```

This prints `Hello, world!`. The entry parser accepts `package require
machteld`, an optional literal version, or `package require -exact machteld
<version>`. Generic Tcl scripts without that declaration are refused.

For a supervised child, save the following as `supervise.tcl` beside `app.tcl`
and run it with the distribution executable. This is a direct-script example:
a wrapped application's own executable enters its application, so a wrapped
controller needs explicit worker-role dispatch, as demonstrated by the
[project inspector](examples/project-inspector/README.md).

<!-- machteld-example: supervise -->
```tcl
package require machteld 0.22
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
- Runtime support: `version`, `manifest`, `docs`, `help`, and `wrap`.

Commands live in `::machteld`; the prelude adds it to the global command path.
`manifest` describes the running executable's verbs, options, fixed result
shapes, and errors. `docs` reads its embedded Machteld, Tcl, and Tk corpus:

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

## Standalone tools

From the directory containing the first program:

<!-- machteld-example: wrap -->
```text
machteld.exe wrap app.tcl -o app.exe
app.exe world
machteld.exe wrap app.tcl -o documented-app.exe --with-docs
documented-app.exe world
```

Both tools expose the same machine-control/data API and required license notices.
Candidate wrapping omits the built-in reference by default; `--with-docs`
includes the complete verified Machteld/Tcl/Tk corpus. Application assets are
unaffected. Without the corpus, `docs schema` and `manifest` remain available,
corpus queries report `DOCS unsupported`, and bare `help` explains the omission.
Wrapping basekits are not embedded recursively.

For larger applications, use a dedicated stage and an explicit UTF-8 dictionary
manifest. `--plan` previews selected paths, sizes, and hashes without writing
an executable. Without a manifest, directory wrapping includes all files,
**including hidden files**: do not wrap a repository root. The stage and
completed archive are checked before atomic publication, but sources must
remain stable; this is not a hostile-filesystem snapshot or sandbox.

Optional metadata sets the application's name, version, description,
authorship, and icon without a compiler. Application identity is separate from
Machteld's runtime identity; a publisher string is not an Authenticode
signature, and signing is never automatic. See [packaging](docs/packaging.md),
the [GUI example](examples/project-inspector/README.md), and the
[adjacent-DLL example](examples/external-extension/README.md) for tested workflows.

## Development checks

After provisioning the pinned build dependencies, invoke the incremental build
explicitly with `.cache/deps/prefix/bin/tclsh90s.exe tools/dev.tcl build`.
The owner's `z devbuild` is a convenience alias, not an additional dependency
for running the delivered executable. Tests select an existing artifact:
`./tools/test.ps1 -Group fast`, `integration`, `packaging`, or
`native-validation`, with `-Machteld <path>` to override `out/machteld.exe`.
These groups never rebuild the runtime or regenerate reference documentation.

`reference-generator` separately checks independent cold conversions, warm-cache
equality, and authored-page invalidation. `native-validation` adds bounded
lifetime/scaling tests, compiler analysis, and available instrumentation with
negative controls; [its guide](docs/native-validation.md) records coverage gaps.
`-InteractiveGui` opens a real Tk window only when explicitly selected.
`-Group release` performs a clean build at the selected output path and then
every group; it does **not** sign or publish, nor automatically enable public
TLS or interactive acceptance.

Upstream Tcl/Tk reference conversion is cached separately from authored pages
and final catalog assembly. Documentation edits reuse upstream conversion;
Tcl implementation-only edits repackage. Unchanged builds skip these stages.
Cache hits verify content and inventories, not timestamps. The version check
rejects recognizable stale current-runtime claims and malformed historical
annotations; genuine release history keeps its original numbers. It is a
guardrail, not a substitute for reviewing prose against behavior. The fast
and packaging groups execute the marked README examples themselves.

The bundled Tcl is 9.0.4 with the pinned upstream ACL-path correction for
[ticket d40d8db3](https://core.tcl-lang.org/tcl/tktview/d40d8db3fb). Dependency
versions, source hashes, and the backport identity are recorded in
[the lock](tools/dependencies.lock.json). Machteld's Windows file/product
version is exactly `0.22`; its author, publisher, and copyright holder are
Vincent Vercauteren. Build paths are scrubbed from the packaged runtime.

Start with [the documentation index](docs/index.md) or the
[agent bootstrap](docs/reference/machteld/agent.md).

Machteld's own code is licensed under the [Apache License 2.0](LICENSE).
Bundled material retains its own terms, including the verbatim
[Tcl](licenses/Tcl-9.0.4.txt), [Tk](licenses/Tk-9.0.4.txt),
[zlib](licenses/zlib-1.3.2.txt), [LibTomMath](licenses/LibTomMath-1.3.0.txt), and
[yyjson](licenses/yyjson-0.12.0.txt) notices. The statically linked SQLite
amalgamation is public domain. JSONTestSuite is test-only and retains
[its own license](test/jsontestsuite/LICENSE).
