# Building machteld

`machteld.exe` is built and signed on the build PC, the owner's machine with
this repository at `C:\dev\machteld`. Unsigned builds run there only, and only
for building and testing; every other machine runs signed releases only.
Signing is the owner's step. Everything below runs from the repository root in
PowerShell.

## What the build stands on

1. **The build runtime: the signed 0.21 at `dist\0.21\machteld.exe`,** a copy
   of the 0.21 release's executable that git ignores (SHA-256
   `1027eef12fdb5512fb28cebb539abfac798fa32f055ec62c82e48a56ca51f3f7`, signed
   by Open Source Developer Vincent Vercauteren). The build tools and the
   driver tests are machteld programs whose first line requires the 0.21, so
   they run on it and refuse 22. When a signed 22 exists, they move to it
   (their first line becomes `package require machteld 22-`). Three
   interpreters share the work:
   - the build runtime runs `tools\bootstrap.tcl`, `release.tcl`, `gate.tcl`,
     `dev.tcl`, `reference.tcl` (the reference generator) and
     `native-analysis.tcl`, and the driver tests: entry, package and
     publication, VERSIONINFO, reference generator and serializer, application
     identity, the development cache and the gate's own;
   - the dependency cache's static Tcl, `.cache\deps\prefix\bin\tclsh90s.exe`,
     runs `tools\build.tcl`, which compiles, links and packages both hosts
     (with `buildlib.tcl`, `package.tcl`, `genmanifest.tcl` and
     `generate-version-resource.tcl`), `check_reference.tcl`,
     `check_version.tcl` and its regression test, the build-identity test,
     and the reference generator's upstream converter and final validator;
   - the runtime under test, `out\machteld.exe`, runs every test lane.
2. **MSYS2 UCRT64, exactly as `tools\dependencies.lock.json` pins it:** gcc
   16.1.0 (`mingw-w64-ucrt-x86_64-gcc` 16.1.0-5), binutils 2.46-3, make
   4.4.1-4 and zip 3.0-4. The bootstrap compares `gcc.exe`, `strip.exe`,
   `windres.exe`, `mingw32-make.exe` and `zip.exe` with the lock's SHA-256
   values and stops on any difference. The gate, the release build and the
   bootstrap find MSYS2 with `--msys DIR`, else `MSYS2_ROOT`, else
   `C:\msys64`; the development loop reads `MSYS2_ROOT`, else `C:\msys64`. On
   the build PC it is `C:\dev\.z\r\msys2`: pass `--msys C:\dev\.z\r\msys2`, or
   set `MSYS2_ROOT` for `tools\dev.tcl`. bash runs only inside MSYS2, for
   Tcl/Tk's configure and make.
3. **The pinned sources:** Tcl/Tk 9.0.4, SQLite 3.53.4 and yyjson 0.12.0. The
   bootstrap fetches a missing archive into `.cache\deps\downloads` with
   Windows' own `curl.exe` and checks each by SHA-256; an archive already
   there with the right hash is used as it is, so the build PC, whose
   downloads folder holds all four, needs no network. Later builds reuse
   `.cache\deps`.

## Build and test

1. The gate builds `out\machteld.exe` and then tests it completely:

   ```text
   & .\dist\0.21\machteld.exe tools\gate.tcl --msys C:\dev\.z\r\msys2
   ```

   It bootstraps or verifies the dependency cache, generates the reference
   corpus, compiles both hosts with `-Werror` and packages them
   (`tools\release.tcl`, which runs `tools\build.tcl` on the cache's Tcl), and
   publishes `out\machteld.exe`. It then runs every test group (fast,
   integration, packaging, native-validation and reference-generator), the
   lanes on that executable; native-validation ends with the full native
   analysis, `tools\native-analysis.tcl`, which writes its report to a fresh
   `out\native-analysis-<id>\`. The first failure stops it, and a green run
   ends with `ALL TEST LANES PASSED` and exit code 0. It names the tested
   executable by version and SHA-256, and fails if the file changes during
   the run. A full run takes about twenty-five minutes on the build PC.
   - `--skip-build` tests `out\machteld.exe` as it is, and `--skip-build
     --runtime FILE` another executable as it is. The gate's build goes to
     `out\machteld.exe` only: it refuses `--runtime` when it would build,
     because the build would replace that file.
   - `--group NAME`, repeatable, runs just those groups and builds nothing,
     on `out\machteld.exe` or on `--runtime FILE`; the fast group needs no
     MSYS2.
   - Off by default, and the owner's to run: `--public-tls` (it reaches public
     hosts), `--interactive-pty` (console input and output) and
     `--interactive-gui` (it opens windows).
2. When the dependency cache is cold or invalidated, build it alone first; Tcl
   and Tk are configured and built in MSYS2's bash, which takes several
   minutes:

   ```text
   & .\dist\0.21\machteld.exe tools\bootstrap.tcl --msys C:\dev\.z\r\msys2
   ```

   `--verify-only` checks a cache and changes nothing.
3. To build without the tests:

   ```text
   & .\dist\0.21\machteld.exe tools\release.tcl --msys C:\dev\.z\r\msys2
   ```

   `--output FILE` publishes elsewhere; `--skip-bootstrap` only verifies the
   cache instead of rebuilding a stale one.

## Signing

Signing is the owner's step, on the build PC, with signtool from the Windows
SDK and the Certum code-signing certificate of Open Source Developer Vincent
Vercauteren. The exact recipe is written at release. Its shape: sign a copy at
a release path, never `out\machteld.exe`, which the gate and the development
loop rewrite; the signature follows the appended payload, and the signed 0.21
shows that the runtime still finds its payload then; and run the gate on the
signed bytes without rebuilding them (`--skip-build --runtime FILE`; without
`--skip-build` the gate refuses `--runtime`). No gate run signs anything or
publishes a release: the one file it publishes is its own build,
`out\machteld.exe`.

## What this is not

1. `tools\dev.tcl` is the incremental development loop (`docs`, `build`, `test
   LANE`, `clean`), run on the build runtime the same way, with `MSYS2_ROOT`
   set. It caches objects and reference generations by content in
   `.cache\dev` and publishes `out\machteld.exe`, the path the gate uses. Only
   the gate decides a release.
2. A new runtime version is one natural number higher: `MACHTELD_VERSION` in
   `src\machteld.h`, `variable version` in `tcl\machteld.tcl`, and a `## N`
   section in `docs\roadmap.md`. `tools\check_version.tcl`, part of the gate,
   refuses any current claim of another version outside the history markers.
