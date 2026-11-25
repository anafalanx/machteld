# Building machteld

The owner builds and signs releases on the build PC with the repository at
`C:\dev\machteld`. Hosted Windows CI may build and run an unsigned candidate
and its packaged application examples. Keep those executables inside the job. CI can
publish test results and checksums. Run the commands below from the repository
root in PowerShell.

0.30 is the next public release after signed 0.21. The unpublished 0.22
candidate supplies the starting source. The current CLI and Tcl package
both report `30`. The earlier Beta 1 run produced an unsigned test
ZIP before the current CI policy was adopted.
[Beta 1 results](docs/releases/0.22-beta.1.md) ·
[Implementation and release gates in the release plan](plan-machteld22.md)

## What the build stands on

1. **The build runtime: the signed 0.21 at `dist\0.21\machteld.exe`,** a copy
   of the 0.21 release's executable that git ignores (SHA-256
   `1027eef12fdb5512fb28cebb539abfac798fa32f055ec62c82e48a56ca51f3f7`, signed
   by Open Source Developer Vincent Vercauteren). The build tools and the
   driver tests are machteld programs whose first line requires 0.21. Use
   this signed driver through the 0.30 build and signed-file acceptance.
   After publication, qualify any driver switch to signed 0.30 in a
   separate change. Three interpreters share the work:
   - the build runtime runs `tools\bootstrap.tcl`, `release.tcl`, `gate.tcl`,
     `dev.tcl`, `reference.tcl` (the reference generator) and
     `native-analysis.tcl`, and the driver tests: entry, package and
     publication, VERSIONINFO, archive integrity, reference
     generator and serializer, the development cache and the gate's own;
   - the dependency cache's static Tcl, `.cache\deps\prefix\bin\tclsh90s.exe`,
     runs `tools\build.tcl`, which compiles, links and packages the shared runtime
     (with `buildlib.tcl`, `package.tcl`, `genmanifest.tcl` and
     `generate-version-resource.tcl`), `check_reference.tcl`,
     `check_version.tcl` and its regression test, the build-identity test,
     and the reference generator's upstream converter and final validator;
   - the runtime under test runs the lanes. The release gate uses
     `out\machteld.exe` by default. Incremental tests use
     `out\dev\machteld.exe`.
2. **MSYS2 UCRT64, exactly as `tools\dependencies.lock.json` pins it:** gcc
   16.1.0 (`mingw-w64-ucrt-x86_64-gcc` 16.1.0-5), binutils 2.46-3, make
   4.4.1-4, zip 3.0-4 and `mingw-w64-ucrt-x86_64-windows-default-manifest`
   6.4-4. The bootstrap compares `gcc.exe`, `strip.exe`, `windres.exe`,
   `mingw32-make.exe`, `zip.exe` and the `default-manifest.o` resolved by
   that GCC with the lock's SHA-256 values and stops on any difference.
   The gate, the release build and the
   bootstrap find MSYS2 with `--msys DIR`, else `MSYS2_ROOT`, else
   `C:\msys64`; the development loop reads `MSYS2_ROOT`, else `C:\msys64`. On
   the build PC it is `C:\dev\.z\r\msys2`: pass `--msys C:\dev\.z\r\msys2`, or
   set `MSYS2_ROOT` for `tools\dev.tcl`. bash runs only inside MSYS2, for
   Tcl/Tk's configure and make.
3. **The pinned sources** include Tcl/Tk 9.0.4, SQLite 3.53.4, yyjson 0.12.0,
   cffi and its dependencies, Graphviz 16.1.2 and Expat 2.8.1. The bootstrap
   fetches their source archives and the matching upstream SQLite Tcl binding
   into `.cache\deps\downloads` with Windows' own
   `curl.exe`. It verifies each file by SHA-256 and reuses matching cached
   downloads. Later builds reuse `.cache\deps`.

## Build and test

1. The gate builds `out\machteld.exe` and then tests it completely:

   ```text
   & .\dist\0.21\machteld.exe tools\gate.tcl --msys C:\dev\.z\r\msys2
   ```

   It bootstraps or verifies the dependency cache, generates the reference
   corpus, compiles the shared runtime with `-Werror` and packages it
   (`tools\release.tcl`, which runs `tools\build.tcl` on the cache's Tcl), and
   publishes `out\machteld.exe`. It runs the fast, integration, packaging,
   native-validation and reference-generator test groups on that executable.
   Native validation ends with `tools\native-analysis.tcl`, which writes its report to a fresh
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
   - Optional lanes include `--public-tls` (public hosts),
     `--interactive-pty` (console input and output) and
     `--interactive-gui` (opens windows and compiles a Win32 window fixture).
     The beta's disposable Windows runner also exercises clipboard ownership
     while a second process uses the same clipboard.
2. When the dependency cache is cold or invalidated, build it alone first; Tcl
   and Tk are configured and built in MSYS2's bash, which takes several
   minutes:

   ```text
   & .\dist\0.21\machteld.exe tools\bootstrap.tcl --msys C:\dev\.z\r\msys2
   ```

   `--verify-only` checks a cache and changes nothing.
3. To make a standalone clean build for comparison:

   ```text
   & .\dist\0.21\machteld.exe tools\release.tcl --msys C:\dev\.z\r\msys2
   ```

   The standalone build defaults to `out\candidate\machteld.exe`. Use
   `--output FILE` to place a comparison build elsewhere. The gate explicitly
   requests `out\machteld.exe`. Use `--skip-bootstrap` to verify an existing
   dependency cache when rebuilding it would defeat the comparison.

## Reconciliation and acceptance

Keep commit ancestry, branches and release tags when integrating on local
`main`. Push the reconciled source directly to GitHub `main` after its
checks pass. Record the tested commit and executable hash with the results.

For the final 0.30 commit, clear the prerelease marker in `src/machteld.h`
and verify Windows file version `30.0.0.0`. Rebuild that commit on the build
PC and the hosted Windows runner, each from a clean checkout and a fresh
dependency cache. Use the same locked inputs and the commit timestamp from
`git show -s --format=%ct HEAD` as `SOURCE_DATE_EPOCH`. Compare the SHA-256
of the complete unsigned executable on each machine. The hashes must match.
Record the hashes, commit, epoch and toolchain receipts. Compare the
incremental build separately and account for its development-only
`build-info.dict`. The existing hosted workflow also checks a second build
in a clean checkout on the same runner.

Substituting the hosted `default-manifest.o` on the build PC reproduced the
original hosted executable hash. CI now installs the locked manifest package
and records the SHA-256 of the object selected by GCC. The resource tests
compare the runtime’s linked RT_MANIFEST with the authored file, and check
the console subsystem and detached console allocation setting.
[Implementation and release gates in the release plan](plan-machteld22.md)

Run the runtime checks and packaged sample applications for 0.30. Automate
repeatable GUI checks on an isolated desktop. Before release, verify
user-visible behavior, including foreground window presentation, in an
attended desktop session. Record the Windows target and result for each.
The porting project supplies its managed-desktop tests for profile
migration, backup and restore, updates and attended sign-in. Qualify the
signed runtime and application archive on the target share and desktop.

## Signing

Signing is the owner's step, on the build PC, with signtool from the Windows
SDK and the Certum code-signing certificate of Open Source Developer Vincent
Vercauteren. After acceptance, the owner signs a copy at a dedicated release
path. The signature follows the appended payload. The signed 0.21 release
demonstrated that the runtime could still find that payload. Verify the
signature and signer on the 0.30 copy. Run the gate on that exact file
with `--skip-build --runtime FILE`, using the signed 0.21 driver. Record
the signed file's SHA-256 and obtain the owner's publication decision.

## Incremental builds and version numbers

1. `tools\dev.tcl` is the incremental development loop (`docs`, `build`, `test
   LANE`, `clean`), run on the build runtime the same way, with `MSYS2_ROOT`
   set. It writes its executable to `out\dev\machteld.exe`. It caches
   objects and whole reference generations by content in `.cache\dev`.
   A documentation edit regenerates the reference, which takes about a minute
   on the build PC. An unchanged reference reuses its cached generation.
2. The development source uses runtime number `30`. Keep
   `MACHTELD_VERSION` in `src\machteld.h`, `variable version` in
   `tcl\machteld.tcl`, and the current-runtime heading in `docs\roadmap.md`
   consistent. The gate checks these values with `tools\check_version.tcl`.
