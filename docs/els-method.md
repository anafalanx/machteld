---
type: guide
title: The els method
description: One-exe Windows applications in C and Tcl/Tk 9, the method els and machteld were built with.
tags: [machteld, els, method, tcl, tk, c, windows]
---

> This guide is `the-els-method.md` of the z repository
> (github.com/anafalanx/z) at df38fae, 2026-09-25, its newest version, and
> the text below this note is unchanged. zef kept a copy as
> `notes\els-method.md` (zef 338e534, 2026-10-28); machteld embeds it as
> `machteld/guide/els-method` from 2026-10-30. Where it describes machteld, it
> describes the runtime as it was then: for this runtime's behavior, the
> [command reference](reference/machteld/index.md) and `manifest` decide.

# The els method — one-exe Windows applications in C and Tcl/Tk 9

*A complete, self-contained methodology for building Windows applications the way
els was built: a small C host, the application in Tcl/Tk, statically linked
Tcl/Tk 9, everything fused into one executable. Written so that an agent given
only this document, a standard MSYS2 compiler, and the standard Tcl/Tk 9 sources
can produce a correct application — and so that the traps that cost real
debugging time here are paid for once, on this page, instead of again in every
new project.*

*Extracted from the els editor (the exemplar: ~375 KB of application Tcl over
six small C files, shipped as one signed exe) and from machteld (which was
carved from els and re-verified every rule below the hard way); later sections
were paid for by the wider estate — the provenance note at the end names each
contributor. Versions are pinned where behaviour was verified: **Tcl/Tk 9.0.4**, **MSYS2 UCRT64 gcc**
(16.x at the time of writing), 64-bit Windows. Newer versions probably work;
they have not been proven here, and every claim in this document is a claim
about what was proven.*

---

## 1. The shape

A finished application is **one PE file** with three layers:

```
┌─────────────────────────────────────────────┐
│  PE image (the "bare" exe)                  │
│    · your C host  (~200 lines)              │
│    · your static C extensions (optional)    │
│    · libtcl9tk90.a + libtcl90.a  (Tcl/Tk 9, │
│      statically linked — no DLLs)           │
│    · icon / version info / app manifest     │
│      (baked in as PE resources)             │
├─────────────────────────────────────────────┤
│  appended ZIP archive ("zipfs payload")     │
│    · main.tcl          — the application    │
│    · tcl_library/      — Tcl's script lib   │
│    · tk_library/       — Tk's script lib    │
│    · resources/        — images, data       │
│    · LICENSE.txt, THIRD-PARTY-NOTICES.txt   │
└─────────────────────────────────────────────┘
```

At startup, Tcl's own `TclZipfs_AppHook` discovers the ZIP appended to the
running executable, mounts it at `//zipfs:/app`, points `tcl_library` into it,
and registers `//zipfs:/app/main.tcl` as the startup script. `Tk_Main` then runs
that script and enters the event loop. Nothing is extracted to disk; the app
runs out of its own file.

**Why this shape.** The deployment story is the whole argument: the artefact is
one file that runs on a machine with *nothing* installed — no Tcl, no runtime
redistributable, no installer, no registry writes. Copy it to an SMB share and a
colleague double-clicks it. The runtime is version-exact by construction (the
app can never meet a different Tcl than the one it was tested with), and there
is no DLL to go missing or be planted. els ships this way; so does machteld;
so did tclkit/starpacks for two decades before them — this is the modern,
zipfs-native form of that lineage.

**The division of labour** is the second half of the shape, and it has a rule
that was re-learned expensively during the machteld/z work:

> **Tcl/Tk for the application; C only for what Tcl cannot reach.**

"Cannot reach" means: a Win32 semantic Tcl's portable layer flattens (see the
traps in §10 — Tcl's `file` commands *lie* about junctions and file identity on
Windows), a hot path measured to matter, a native binding (drag-and-drop,
ICU, atomic ReplaceFileW), or antialiased rendering — Tk's canvas has none,
and §13 is the proven escape. It does **not** mean "C because C feels more
serious". els is ~375 KB of Tcl and six small C files; every attempt to move
that boundary further into C in this workspace produced memory-safety bugs
(a bounds check 12 bytes short, a 93-bytes/call refcount leak) that Tcl code
structurally cannot have. When you do write C, write it against a hostile
fixture first (§11).

---

## 2. Prerequisites, and building the static runtime

You need exactly two things beyond Windows:

1. **MSYS2** with the UCRT64 toolchain:

   ```
   pacman -S mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-binutils \
             mingw-w64-ucrt-x86_64-make zip
   ```

   That provides `gcc`, `windres`, `strip`, `mingw32-make`. UCRT64 (not
   MINGW64): the UCRT is the modern Windows C runtime, present on all supported
   Windows versions.

2. **Tcl and Tk 9.0.4 sources**, from the official releases:

   - `https://github.com/tcltk/tcl/releases/download/core-9-0-4/tcl904-src.zip`
   - `https://github.com/tcltk/tcl/releases/download/core-9-0-4/tk904-src.zip`

   (Pin the SHA-256 of what you download. machteld records
   `f37b22a6…` for the Tcl zip; verify against the release page.)

**Build both statically**, from an MSYS2 UCRT64 shell, into a prefix of your
choosing (`$PREFIX` below). This is the exact, verified recipe:

```bash
export PATH="/ucrt64/bin:/usr/bin:$PATH"
export CC=gcc AR=ar RANLIB=ranlib RC=windres

cd tcl9.0.4/win
./configure --enable-64bit --disable-shared --enable-threads --prefix="$PREFIX"
mingw32-make -j8 binaries
mingw32-make install-binaries install-libraries install-headers

cd ../../tk9.0.4/win
./configure --enable-64bit --disable-shared --enable-threads \
    --with-tcl="$PWD/../../tcl9.0.4/win" --prefix="$PREFIX"
mingw32-make -j8 binaries
mingw32-make install-binaries install-libraries
```

Notes that earn their place:

- `--disable-shared` is what makes the `.a` files complete static archives and
  the built `tclsh90.exe` / `wish90.exe` genuinely standalone. (By convention
  this workspace names static copies `tclsh90s.exe` / `wish90s.exe`; upstream
  does not add the `s`.)
- Only `binaries` + the three `install-*` targets are needed. Upstream's
  aggregate `all` / `install` also build bundled extension packages and
  manuals, none of which are linked or packaged here. (If an app wants a
  bundled package — sqlite3, Thread — build and stage it deliberately;
  §15 and §18 record the workspace instances and their limits.)
- After this, the prefix contains everything the method uses:

  | Path | What |
  |---|---|
  | `$PREFIX/bin/tclsh90.exe`, `wish90.exe` | static shells — `tclsh90` also serves as the **build tool** (it runs the packaging script) |
  | `$PREFIX/lib/libtcl90.a`, `libtcl9tk90.a`, `libtclstub.a` | the archives your host links |
  | `$PREFIX/include/` | `tcl.h`, `tk.h` — the 9.x headers |
  | `$PREFIX/lib/tcl9.0/`, `$PREFIX/lib/tk9.0/` | the script libraries that become `tcl_library/` and `tk_library/` in your payload |

**The version trap, stated now because it bites silently:** MSYS2's own
repositories carry Tcl/Tk **8.6** for their own purposes. If a bare `tclsh` or a
stray `-I/ucrt64/include` ever resolves to it, you get 8.6 headers against 9.0
libraries or vice versa, and the failures are downstream and baffling. The rule
els enforces mechanically: *every* interpreter invocation and *every* `-I`/`-L`
uses an explicit path into `$PREFIX`; nothing is taken from `PATH`.

---

## 3. The host

The host is a deliberately small C file. This is the complete GUI-application
form, distilled from `els_main.c` (which is itself a minimal fork of Tk's own
`win/winMain.c`, the literal source of `wish.exe`) — the comments are part of
the method, keep them:

```c
/* app_main.c -- the one-exe host: GUI subsystem, static Tcl/Tk 9, zipfs app.
 *
 * Load-bearing build flags -- each failure mode below was observed, not guessed:
 *   -municode -DUNICODE -D_UNICODE : TclZipfs_AppHook has a WCHAR signature;
 *                                    without UNICODE the self-mount silently
 *                                    NO-OPS and main.tcl is never found.
 *   -DSTATIC_BUILD=1               : otherwise tcl.h/tk.h mark API symbols
 *                                    dllimport and the static link fails.
 *   USE_TCL_STUBS must be UNDEFINED: with stubs, Tk_Main becomes a TIP-596
 *                                    thunk that LoadLibrary's tcl90.dll -- which
 *                                    a static exe does not have -- and crashes.
 *   -mwindows                      : GUI subsystem (no console window).
 */
#undef USE_TCL_STUBS
#include "tk.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#undef WIN32_LEAN_AND_MEAN
#include <locale.h>
#include <tchar.h>

#if defined(__GNUC__)
int _CRT_glob = 0;   /* keep the mingw CRT from glob-expanding argv: "*.txt"
                      * passed by a user must arrive as "*.txt". */
#endif

/* Statically linked extensions declare their Init here (no public headers). */
/* extern int Myext_Init(Tcl_Interp *interp); */

static int App_AppInit(Tcl_Interp *interp);

/* A GUI-subsystem process has no console, so returning TCL_ERROR from AppInit
 * is NOT fail-closed: Tk_Main shows a warning and then continues into main.tcl
 * with a half-initialized interpreter. Report once, then END the process. */
static _Noreturn void
InitFailure(Tcl_Interp *interp, const WCHAR *stage)
{
    WCHAR detail[1536] = L"No further detail was provided.";
    WCHAR body[2048];
    const char *msg = Tcl_GetStringResult(interp);
    if (msg != NULL && *msg != '\0') {
        if (MultiByteToWideChar(CP_UTF8, 0, msg, -1, detail,
                (int)(sizeof(detail) / sizeof(detail[0]))) == 0) {
            wcscpy(detail, L"The diagnostic could not be decoded.");
        }
    }
    swprintf(body, sizeof(body) / sizeof(body[0]),
             L"This application cannot start: %ls failed.\n\n%ls",
             stage, detail);
    MessageBoxW(NULL, body, L"Application", MB_ICONERROR | MB_OK);
    ExitProcess((UINT)EXIT_FAILURE);
}

int APIENTRY
_tWinMain(HINSTANCE hInstance, HINSTANCE hPrev, LPTSTR lpszCmdLine, int nCmdShow)
{
    TCHAR **argv; int argc; TCHAR *p;
    (void)hInstance; (void)hPrev; (void)lpszCmdLine; (void)nCmdShow;

    setlocale(LC_ALL, "C");   /* predictable number/path parsing */

    /* Args from the CRT (wide under -municode); never parse lpszCmdLine. */
    argc = __argc;
    argv = __targv;

    /* Forward slashes in argv[0], as wish itself does. */
    for (p = argv[0]; *p != '\0'; p++) { if (*p == '\\') *p = '/'; }

    /* Self-mount the ZIP appended to THIS exe at //zipfs:/app and register
     * //zipfs:/app/main.tcl as the startup script. UNICODE-only signature. */
#if defined(UNICODE)
    TclZipfs_AppHook(&argc, &argv);
#endif

    /* REFUSE to run as a generic script host. If the payload did NOT mount
     * (stripped/corrupted exe -- e.g. a PE-resource tool rewrote the image and
     * dropped the appended archive), no startup script was registered, and
     * Tk_Main would fall back to wish semantics: SOURCE THE FIRST ARGUMENT as
     * Tcl. A double-clicked "document" would then execute arbitrary code. An
     * intact exe always has its script registered by this point. */
    if (Tcl_GetStartupScript(NULL) == NULL) {
        MessageBoxW(NULL,
            L"This application cannot start: its embedded payload is missing "
            L"or corrupt. The executable may be damaged.",
            L"Application", MB_ICONERROR | MB_OK);
        return 1;
    }

    Tk_Main(argc, argv, App_AppInit);
    return 0;                 /* not reached; Tk_Main does not return */
}

/* The payload is the exe's only script library and its only package source
 * (trap 19). Stock Tcl consults $env(TCL_LIBRARY) before the zipfs mount
 * and Tk consults $env(TK_LIBRARY) before it; a preset tcl_library /
 * tk_library is the one place both searches honour first. init.tcl fills
 * auto_path from $env(TCLLIBPATH) and <exe>/../lib, tm.tcl adds module roots
 * from TCL9_0_TM_PATH and <exe>/../lib/tcl9 -- and Tk_Init's tk.tcl runs
 * `package require msgcat`, whose search SOURCES every pkgIndex.tcl on
 * auto_path. So the search is narrowed to the payload before Tk_Init. */
static const char pinPackages[] =
    "set ::auto_path [list $::tcl_library [file dirname $::tcl_library]]\n"
    "::tcl::tm::path remove {*}[::tcl::tm::path list]\n";

static int
App_AppInit(Tcl_Interp *interp)
{
    if (Tcl_SetVar2(interp, "tcl_library", NULL, "//zipfs:/app/tcl_library",
            TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG) == NULL) {
        InitFailure(interp, L"pinning tcl_library");
    }
    if (Tcl_Init(interp) == TCL_ERROR) {
        InitFailure(interp, L"Tcl initialization");
    }
    if (Tcl_EvalEx(interp, pinPackages, TCL_INDEX_NONE, TCL_EVAL_GLOBAL) != TCL_OK) {
        InitFailure(interp, L"pinning the package search");
    }
    if (Tcl_SetVar2(interp, "tk_library", NULL, "//zipfs:/app/tk_library",
            TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG) == NULL) {
        InitFailure(interp, L"pinning tk_library");
    }
    if (Tk_Init(interp) == TCL_ERROR) {
        InitFailure(interp, L"Tk initialization");
    }
    Tcl_StaticLibrary(interp, "Tk", Tk_Init, Tk_SafeInit);

    /* Each static extension: run its Init, then register it so `package
     * require` and slave interps can find it.
    if (Myext_Init(interp) == TCL_ERROR) {
        InitFailure(interp, L"myext initialization");
    }
    Tcl_StaticLibrary(interp, "Myext", Myext_Init, NULL);
    */

    return TCL_OK;
}
```

**The console variant** (for CLI tools, or a debugging twin of a GUI app)
differs in four ways: entry point is `int wmain(int, wchar_t **)`
calling `Tcl_Main(argc, argv, App_AppInit)` (from `tcl.h`; include `tk.h` only
if the tool may use Tk), link **without** `-mwindows`, skip `Tk_Init` unless
wanted, and let `InitFailure` and the damaged-exe refusal write to `stderr`
instead of calling `MessageBoxW`. Everything else — the flags, the AppHook, the
refusal itself, the payload pinning — is identical. Keep a console twin
buildable even for a GUI app: it is how you see `stderr` when something goes
wrong (§10, trap 4). A Tk app's twin keeps `Tk_Init` and **still enters
through `Tcl_Main`, never `Tk_Main`**: `Tk_Init` installs Tk's event loop as
`Tcl_Main`'s main loop, so after the startup script the twin runs exactly as
the GUI build does, and an error in that script reaches `stderr` — where
`Tk_Main` would have raised a dialog even in a console process (trap 20).

---

## 4. Compiling and linking

The verified recipe, one translation unit at a time and then one link. `$INC`
is `$PREFIX/include`, `$LIB` is `$PREFIX/lib`.

**Compile** every C file with:

```
gcc -std=c23 -O2 -Wall -Wextra -Werror -no-pthread \
    -DSTATIC_BUILD=1 -ffunction-sections -fdata-sections \
    -c src/foo.c -o build/foo.o -I$INC
```

and the **host** translation unit additionally with:

```
    -municode -DUNICODE -D_UNICODE
```

(plus one `-DAPP_STATIC_MYEXT`-style define per extension you are baking in, so
the host's registration block can be conditional and the extension can also be
built as a dev-time DLL — §8).

**Link** (a GUI app):

```
gcc -no-pthread -municode -mwindows -static-libgcc \
    "-Wl,--gc-sections,--dynamicbase,--nxcompat,--high-entropy-va,--no-insert-timestamp" \
    build/app_main.o build/myext.o build/app.res \
    $LIB/libtcl9tk90.a $LIB/libtcl90.a $LIB/libtclstub.a \
    -lnetapi32 -lkernel32 -luser32 -ladvapi32 -luserenv -lws2_32 \
    -lgdi32 -lcomdlg32 -limm32 -lcomctl32 -lshell32 -luuid -lole32 \
    -loleaut32 -lwinspool \
    -o build/app-bare.exe
strip --enable-deterministic-archives build/app-bare.exe
```

The details that are load-bearing:

- **Library order matters**: your objects, then the `.res`, then **Tk before
  Tcl before stub**. Static archives resolve left to right; Tk needs Tcl's
  symbols.
- **That system-library list is Tk 9's verified closure** (els links exactly
  these fifteen). If your own C uses more Win32, add what the linker asks for —
  machteld adds `-lpsapi -lbcrypt -lwinhttp` for its process/hash/http verbs.
- `-no-pthread` + `-static-libgcc` keep the exe free of `libwinpthread` and
  `libgcc` DLL dependencies. els *asserts* no winpthread appears in the link
  map, because a linked winpthread changes the third-party-notice obligations
  (§7). Generate a map with `-Wl,-Map,build/app.map` if you want the same gate.
- `--gc-sections` (paired with the compile-time `-ffunction-sections
  -fdata-sections`) drops unreferenced code; `--dynamicbase --nxcompat
  --high-entropy-va` are the standard hardening bits; `--no-insert-timestamp`
  plus `SOURCE_DATE_EPOCH` (§6) is what makes rebuilds byte-reproducible —
  *exported* to the toolchain before the first compile, because `strip`
  rewrites the PE header and stamps the current time into it otherwise
  (trap 21).
- **Do not define `USE_TCL_STUBS` for the host or static extensions.** Stubs
  are for *loadable* extensions only (§8). `libtclstub.a` still appears in the
  link — Tk's static build references two stub-table symbols — and that is
  fine; what matters is the compile-time define.

---

## 5. PE resources: icon, version info, manifest

A professional exe carries an icon, a `VERSIONINFO` block, and an application
manifest. Generate them at build time (els generates both the `.rc` and the
manifest from Tcl so the repo stays Tcl+C only), compile with `windres`, and
link the resulting `.res` into the **bare** exe:

```
windres --include-dir build --include-dir $INC build/app.rc -O coff -o build/app.res
```

The manifest that els ships, and why each clause is there:

- `requestedExecutionLevel level="asInvoker"` — never trigger UAC.
- **DPI awareness: system-DPI-aware, deliberately *not* PerMonitorV2** — Tk 9.0.x
  does not handle `WM_DPICHANGED`, so PerMonitorV2 gives you blurry or
  wrongly-sized windows when monitors differ; system-aware is what Tk actually
  supports.
- Common Controls v6 dependency — native-themed widgets.
- `longPathAware` — lifts MAX_PATH for the Win32 APIs that honour it.
- Active code page UTF-8 — `char*` Win32 APIs interpret UTF-8.

Version numbers should have **one source of truth**: els keeps
`variable version "0.x"` in the application Tcl and the resource generator
reads it out with a regexp — nothing to keep in sync.

> **THE PE-RESOURCE GOTCHA (this destroys shipped exes):** bake resources into
> the bare PE **first**, and only then append the zipfs payload. Tools that
> edit resources afterwards (`UpdateResource`, Resource Hacker, some signing
> wrappers) rewrite the PE image and **silently drop the appended archive** —
> the exe then starts, finds no `init.tcl`, and dies. The damaged-exe refusal
> in the host (§3) exists precisely so this failure is a clear dialog instead
> of arbitrary-script-execution wish semantics. Authenticode signing with
> `signtool` is safe *after* packaging — signatures are designed to coexist
> with appended data — but resource editing is not.

---

## 6. The payload, and fusing it

Packaging is a ~40-line Tcl script **run under the static `tclsh90.exe` from
your prefix** (it must be the static one: the build machine may have no other
Tcl, and the packager itself needs `zipfs`). The steps, verbatim from els's
`tools/package.tcl` with the project-specifics removed:

1. **Stage** a scratch directory with exactly this layout:

   ```
   payload/
     main.tcl               ← your application (els stages els.tcl AS main.tcl)
     tcl_library/           ← copied from $PREFIX/lib/tcl9.0
     tk_library/            ← copied from $PREFIX/lib/tk9.0
     resources/             ← your images/data (els copies exactly what git
                              tracks — `git ls-files -z -- resources` — so an
                              untracked editor backup can never ship)
     LICENSE.txt
     THIRD-PARTY-NOTICES.txt
   ```

   A neat alternative source for `tk_library`: mount the static wish and copy
   it out of the shell's own belly —
   `zipfs mount $PREFIX/bin/wish90.exe Wt` → copy `//zipfs:/Wt/tk_library`.

2. **Normalize mtimes** for reproducibility: set every staged file's mtime to
   `SOURCE_DATE_EPOCH` (els uses the HEAD commit time: `git show -s
   --format=%ct HEAD`). With `--no-insert-timestamp` at link, and the same
   value exported as `SOURCE_DATE_EPOCH` for the compile, link and `strip`
   (trap 21), the whole artefact becomes byte-reproducible — which is what
   lets a release gate demand "rebuild and match byte-for-byte before
   signing".

3. **Fuse** — this is the one magic line:

   ```tcl
   zipfs lmkimg out.exe $entries {} bare.exe
   ```

   where `$entries` is the flat `{diskPath zipPath diskPath zipPath …}` list of
   the staged tree (zip paths forward-slashed, relative — `main.tcl`,
   `tcl_library/init.tcl`, …), `{}` is "no password", and `bare.exe` is the
   host from §4 with resources already baked in. `lmkimg` copies the wrapper
   and appends the archive.

4. **Place atomically**: build to a staging name, verify it is a regular file,
   `file rename -force` over the destination. A half-written exe that looks
   whole is the worst artefact to leave behind.

**The notices are not optional.** A one-file binary carries statically-linked
code, so it must carry the licences governing it. The verified obligation set
for this stack: your own licence, **Tcl**, **Tk**, the **MinGW-w64 runtime**,
the **GCC runtime-library exception** (you link `libgcc` statically), **zlib**
(inside Tcl's zipfs), and **LibTomMath** (Tcl's bignum). els embeds the
verbatim files as `THIRD-PARTY-NOTICES.txt` in the payload; do the same.

---

## 7. What actually happens at startup (own this mental model)

1. Windows loads the PE and calls the host's entry point.
2. `TclZipfs_AppHook` inspects **the running executable's own file**, finds the
   appended archive, mounts it at `//zipfs:/app`, offers
   `//zipfs:/app/tcl_library` as Tcl's script library, and — because a root
   `main.tcl` exists — registers it as the interpreter's **startup script**.
   *Offers* is exact: stock Tcl and Tk take their libraries from `TCL_LIBRARY`
   and `TK_LIBRARY` first whenever those name valid ones, which is why §3's
   `AppInit` presets `tcl_library` and `tk_library` (trap 19).
3. `Tk_Main` creates the interpreter, calls your `AppInit` (Tcl init, Tk init,
   your extensions), sources the startup script, **and then enters the event
   loop**. A Tk program written for this host simply builds its UI at top
   level and returns; the loop is the host's job.
4. Your application is now running with `[info nameofexecutable]` = the exe,
   `[info script]` = `//zipfs:/app/main.tcl`, and every payload file readable
   through `//zipfs:/app/…` with ordinary `open`/`source`/`image create`.

Two consequences worth internalizing:

- **The startup script is captured before your code runs.** `Tcl_Main`/`Tk_Main`
  read it into a local before `AppInit` is called; nothing you set from Tcl
  later changes what is about to be sourced. If you ever need "run some other
  script as the program" semantics, you must source it yourself and, for a Tk
  program, hold the process open with `tkwait window .` — because the
  loop-after-return service belongs to the *startup* script only. (machteld's
  dispatcher learned both halves of this by measurement.)
- **State lives beside the exe** (els's convention): config, logs, backups are
  siblings of `[info nameofexecutable]`. One folder = the whole installation;
  moving the folder moves the app and its state; the directory must be
  writable. A source-mode run (§8) uses the script's directory instead —
  derive the state root once, at startup, from whichever mode you are in.

---

## 8. The development loop

The single most valuable property of this method day-to-day: **you do not
package to develop.** The edit-run cycle is:

```
$PREFIX/bin/wish90.exe app.tcl        (GUI)
$PREFIX/bin/tclsh90.exe app.tcl       (console)
```

The application should therefore tolerate both worlds. The pattern, all three
parts verified in els:

- **Optional native features degrade.** els's `package require icudet` is
  wrapped in `catch`; without the extension it falls back to BOM/UTF-8/cp1252
  detection. Every native binding should have a story for "not present".
- **Extensions have two build modes.** During development, build them as
  ordinary **stub-enabled loadable DLLs**:

  ```
  gcc -std=c23 -O2 -Wall -shared -DUSE_TCL_STUBS \
      -I$INC src/myext.c -o build/myext.dll -L$LIB -ltclstub -static-libgcc
  ```

  with a generated `build/pkgIndex.tcl`
  (`package ifneeded myext 0.1 [list load [file join $dir myext.dll] Myext]`)
  so a source-mode run can `package require` them. The **product** build
  compiles the same `.c` files as plain objects (no stubs) and registers them
  in `AppInit` (§3). Same source, two linkages; the `-DAPP_STATIC_*` defines
  in §4 are what let the host register only what is really baked in.
- **A packaged-exe probe exists.** Development testing runs from source, but
  before anything ships, run the *fused* artefact: els copies the candidate
  exe into an isolated directory, launches it as a real child process with
  controlled state paths, and asserts on observable behaviour. A packaged app
  differs from a source run in exactly the ways (§7, §10) that source-mode
  tests cannot see: the zipfs mount, the startup script, the GUI subsystem,
  state-beside-exe.
- **A GUI app needs a headless self-check.** You cannot watch stderr of a
  `-mwindows` process. els ships `--selftest [file [report]]`: boot the full
  app headlessly, write a UTF-16 report file beside the exe, exit nonzero on
  failure. Design this in from day one; it is also what CI would run.

---

## 9. Starting a new application — the checklist

```
myapp/
  app.tcl                 the application; `variable version "0.1"` near the top
  src/
    app_main.c            §3 host, renamed defines
    (myext.c …)           optional native modules
  resources/              tracked assets only
  tools/
    build.tcl             §4–§6 as one script, run by $PREFIX/bin/tclsh90.exe
    genres.tcl            emits app.rc + app.exe.manifest into build/
  build/                  gitignored: objects, .res, staged payloads, dev exe
  LICENSE
```

Order of work:

1. Write `app.tcl`; develop under `wish90.exe app.tcl` until it does something.
2. Copy the §3 host; rename; compile+link the **console** twin first (you get
   stderr); confirm `app-console.exe` runs your script from its payload.
3. Add resources/manifest (§5), switch to `-mwindows`, package (§6).
4. Run the fused exe probe; add the `--selftest` mode.
5. Only now, if a real need exists, write the first C extension — dev-mode DLL
   first, static in the product once it works.

A `build.tcl` of ~150 plain lines covers all of it — compile loop, windres,
link, stage, `lmkimg`, atomic place. els's `tools/tasks.tcl` and machteld's
`tools/build.tcl` are both working references; resist making it cleverer than
that until the app earns it.

---

## 10. The traps

Every entry below was hit in this workspace, by competent people, and cost
real time. Each is a rule plus the observable failure if you break it.

1. **No `-DUNICODE` ⇒ the payload silently never mounts.**
   `TclZipfs_AppHook` uses the WCHAR signature; built narrow, it no-ops. The
   exe starts and cannot find `init.tcl` — or worse, falls into trap 10.

2. **`USE_TCL_STUBS` defined in the host ⇒ crash at startup.** Under TIP 596,
   `Tk_Main` compiles to a thunk that `LoadLibrary`s `tcl90.dll`. A static exe
   has no such DLL. Undefine stubs for the host and static extensions; use
   stubs *only* for dev-mode loadable DLLs.

3. **No `-DSTATIC_BUILD=1` ⇒ link errors (dllimport).** The headers decorate
   the API for DLL import unless told otherwise.

4. **A GUI-subsystem process has no stdio.** `puts stdout` throws
   *"can not find channel named stdout"*; stderr goes nowhere; a console
   window never appears. Consequences: never debug the GUI exe by "running it
   and reading the terminal" — use the console twin or the self-test report;
   and never ship a "GUI" app by flipping the subsystem bit on a console PE —
   build two hosts (this is why els and machteld both carry a console and a
   GUI `main.c`).

5. **`TCL_ERROR` from `AppInit` is not fail-closed in a GUI app.** `Tk_Main`
   warns and *continues* into your script with a half-initialized interp.
   Fail via MessageBox + `ExitProcess` (§3's `InitFailure`).

6. **The startup script is captured before your code runs** (§7). Rewriting
   `argv0` from Tcl changes a variable, not what gets sourced.

7. **The event loop runs after the startup script returns — for the startup
   script only.** A script *you* source that builds a Tk UI and returns will
   exit the process unless you `tkwait window .` (or `vwait forever`).

8. **A root `main.tcl` in the archive is auto-run.** That is the feature — and
   it means "is there a root `main.tcl`?" is the discriminator between "this
   exe is an app" and "this exe is a plain shell". Never place one in a
   payload that is not meant to be a program.

9. **PE-resource editing after packaging destroys the payload** (§5). Bake
   resources first; sign after; never resource-edit a fused exe.

10. **A damaged exe must refuse, not become a script host.** Without the
    §3 guard, Tk_Main falls back to wish semantics and **sources the first
    command-line argument** — a double-clicked document executes arbitrary
    Tcl. Two lines of C close a real vulnerability class.

11. **MSYS2's Tcl 8.6 shadows yours** (§2). Explicit paths, always.

12. **The mingw CRT glob-expands argv unless `_CRT_glob = 0`.** A user's
    literal `*.txt` argument arrives pre-expanded and wrong.

13. **Tcl's filesystem layer lies about Windows objects.** All measured, all
    silent: `file exists` answers **true** for a dangling junction;
    `file normalize` does **not** resolve a reparse point that is the final
    path component; `file stat`'s `dev` is the drive-letter index (not the
    volume serial) and on a junction describes the junction, not the target;
    `glob -types d` misses directories carrying the **hidden attribute**
    (`-types {d hidden}` returns *only* hidden ones — union both). For an
    editor these rarely matter; for anything that walks, mirrors, or reasons
    about identity, they are exactly where a self-consistent wrong answer
    comes from. Push such logic into a small C extension that opens handles
    (`GetFinalPathNameByHandleW`, `GetFileInformationByHandle`), or accept and
    document the limits.

14. **Set `setlocale(LC_ALL, "C")`** in the host; and in Tcl, be explicit
    about encodings at every boundary: `-encoding utf-8` on text files you
    own, `-translation lf` where byte-exactness matters, `rb`/`wb` for
    binary. Windows tools emit the system code page (a robocopy log is not
    UTF-8); decode deliberately, never by default.

15. **Never resolve child-process programs through `PATH` implicitly.** Run
    what you name, by absolute path, or document loudly that you don't. A
    planted exe earlier on `PATH` is the oldest Windows attack there is, and
    "which program did I actually run?" must have one answer.

16. **A native modal dialog must never run from the startup script.** The
    event loop starts only after the startup script returns (§7), and Tk's
    Windows file dialogs deliver their result through the event machinery.
    Observed live (ph, 2026-08-16): `tk_getOpenFile` called from the startup
    script showed its dialog, the user's pick never arrived, and the window
    went Not Responding. Build the UI, return, and schedule anything
    dialog-shaped with `after idle`, giving it an explicit mapped `-parent`.
    els's dialogs — which work daily — are all invoked from key bindings,
    i.e. event-loop time; that is the pattern, not luck.

17. **Inside a proc that lives in namespace `app`, the name `app::thing`
    does not mean what it says.** Qualified names resolve *relative to the
    current namespace first*: `trace add variable app::filter` inside an
    `app::` proc looks for `app::app::filter` ("parent namespace doesn't
    exist"), and `$app::version` fails the same way ("no such variable").
    Both were berg's only two GUI defects (2026-08-18), and both passed
    every headless test — they only fire on the paths that touch them.
    Widget options are immune (`-textvariable app::filter` is resolved by
    Tk in global context), which makes the trap look inconsistent and
    therefore survivable in review. The law: inside namespace code, either
    declare with `variable` and use the bare name, or write the absolute
    `::app::thing` — never the single-colon-pair relative form.

18. **Tcl's allocator belongs to Tcl-registered threads only.** A vendored
    library with worker threads of its own — an embedded interpreter
    running kernels, a hash or compression library in threaded mode —
    allocates on threads Tcl has never seen, and routing that through
    `Tcl_Alloc` is heap corruption on a delay timer, paid three functions
    later on the main thread. Identified while designing reken's parallel
    pool (2026-08-19), cheap there because the law was applied before the
    corruption was: anything a foreign thread may allocate goes through CRT
    `malloc`; every `Tcl_Obj` stays on the interp's own thread (so sharding
    and result assembly happen at home); workers touch only their own
    state.

19. **The payload is the exe's only library only if the host makes it
    so.** Stock Tcl's `tclInit` consults `$env(TCL_LIBRARY)` before the
    zipfs mount, and Tk's `tcl_findLibrary` consults `$env(TK_LIBRARY)`;
    `init.tcl` builds `auto_path` from `$env(TCLLIBPATH)`, `<exe>/../lib`
    and `tcl_pkgPath`, and `tm.tcl` adds module roots from `TCL9_0_TM_PATH`
    and `<exe>/../lib/tcl9`. Measured 2026-09-25 against the static 9.0.4
    runtime: with `TCL_LIBRARY` naming another valid Tcl library, *that*
    `init.tcl` was sourced instead of the payload's. With a decoy planted at
    each of those places, a fused exe built from the §3 host as it then
    stood read the decoy `init.tcl` and `tk.tcl` and **executed** decoy
    `pkgIndex.tcl` files from `TCLLIBPATH` and `<exe>/../lib` — all before
    `main.tcl` ran, because `Tk_Init`'s `tk.tcl` runs `package require
    msgcat`, and that search sources every `pkgIndex.tcl` on `auto_path`.
    So an exe on a share runs whatever anyone can put in `..\lib` beside
    it, and an exe started from a z shell runs the kit's script library
    rather than its own (z exports both variables to every child). §3's
    `AppInit` presets `tcl_library` and `tk_library` — the one place both
    searches honour first ("unless the application has specified an exact
    directory", `tclInterp.c`) — and narrows `auto_path` and the module
    paths to the payload between `Tcl_Init` and `Tk_Init`. Keep it a gate,
    not a belief: vanisha's `kuu run test` starts both builds with every one
    of those places holding a decoy that marks the interpreter if it is
    read. The pinless host failed it, four decoys read or run; the pinned
    host passes, and so does §3's code as printed here.

20. **`Tk_Main` answers a startup error with a dialog, in every
    subsystem.** It reports an error in the startup script through
    `TkpDisplayWarning`, which on Windows is a system-modal, topmost
    `MessageBoxW` unless a debugger is attached (`win/tkWinInit.c`, 9.0.4);
    nothing there asks whether the process has a console. So a "console
    twin" that enters through `Tk_Main` still puts "Error in startup
    script" on the desktop and waits for a click. Observed live 2026-09-25,
    when a self-test run from source under the static `wish` put that
    dialog on the user's screen and the automated run waited for their
    click. `Tcl_Main` writes the error to `stderr` and exits 1
    (`generic/tclMain.c`), and with `Tk_Init` in `AppInit` it still enters
    Tk's event loop after the script, because `Tk_Init` installs it as the
    main loop (`Tcl_SetMainLoop`, `tkWindow.c`). The twin is therefore §3's
    console variant exactly: `Tcl_Main` plus `Tk_Init`. The same goes for
    the source-mode loop (§8): an unattended run of a Tk app belongs under
    a console `tclsh` that loads Tk as a package, not under `wish`.

21. **`strip` restamps the PE header.** `--no-insert-timestamp` keeps the
    link's time out of the image (it writes 0), but `strip` rewrites the
    header: without `-p` it asks BFD for the current time (`objcopy.c` sets
    the PE timestamp to -1, `peXXigen.c` then calls
    `bfd_get_current_time`), which is `SOURCE_DATE_EPOCH` when that is
    defined — an empty value counts as 0 — and the wall clock when it is
    not. Measured 2026-09-25 (binutils 2.46, MSYS2 UCRT64): two builds of
    one unchanged tree, payload mtimes already normalized, differed in
    exactly three bytes of the PE header, the time stamp and the checksum
    over it; with the HEAD commit time exported as `SOURCE_DATE_EPOCH`
    before the first compile, they were byte-identical. Stamping the staged
    files (§6) is not enough; the variable has to reach the tools.

22. **A `-padding` on a Treeview style erases the cells' padding.** Tk fills
    every row's display record from the widget's style, `-padding`
    included, and a record that carries a padding switches off the cells'
    default (four pixels, scaled) and overrides a `Cell` style's own
    (`DrawCells`, `generic/ttk/ttkTreeview.c`). Measured 2026-09-25 on
    otherwise identical treeviews: with any `-padding` on the Treeview
    style, cell text sat flush against both column edges, so a clipped
    value ran straight into its neighbour's; without it, the default
    padding — or a `Cell -padding` — applied. vanisha inherited the setting
    from its Python original (`padding=(0, 1, 0, 1)`). Pad cells through
    the `Cell` style (`ttk::style configure App.Treeview.Cell -padding
    ...`), never the Treeview's.

23. **An image element fills its stretched parts one draw per tile.** An
    element made with `ttk::style element create ... image` stretches its
    image by replication: `Ttk_Fill` (`generic/ttk/ttkImage.c`) calls
    `Tk_RedrawImage` once for every source-sized tile of the area it
    covers. A nine-slice image with a one-pixel centre, the obvious way to
    draw a plain fill with a hairline beside it, therefore costs one image
    draw per pixel of everything painted from it, on every repaint.
    Measured 2026-09-25 on a fused exe at 175% scaling: vanisha's flat
    treeview headings, drawn from a 2×2 image with `-border {0 0 1 1}`,
    cover a row 65 pixels high and some 2,180 wide, about 140,000 draws
    per repaint of that row. Three `--probe` runs took 12, 18 and 24 s from
    start to capture; an otherwise identical build with a 65×65 image, whose
    64-pixel centre makes each heading a few dozen draws, took about 1 s
    each. Make every stretched region of an image element tens of pixels on
    a side, however uniform it is — and give the element
    `-width 0 -height 0`, or the size it needs, because an image element
    asks for its image's size unless told otherwise (`ImageElementSize`):
    the 65-pixel tile had made vanisha's heading row 65 pixels high instead
    of the 54 its text needs. Keep a gate on the tile; vanisha's self-test
    checks its size.

24. **The default theme's `field` element draws a focus ring.** It is what
    a flat design borrows: `ttk::style element create App.field from
    default field`, with `-borderwidth 0`, is a plain fill. But in 9.0.4 it
    also carries `-focuswidth` (default 2) and `-focuscolor` (default
    `#4a6984`). While the widget has the focus it rings the field in that
    colour (`FieldElementDraw`, `generic/ttk/ttkElements.c`), and whenever
    `-borderwidth` is under 2 it reserves `-focuswidth` as padding, focused
    or not (`FieldElementSize`). Measured 2026-09-25 in 1:1 captures of
    vanisha's list on a card with a `#d0d7de` hairline: two pixels of white
    between the hairline and the rows, which turned dark slate as soon as
    the list took the focus. Set `-focuswidth 0` on the style for neither
    ring nor margin, or a `-focuscolor` from the app's own palette if the
    ring is wanted.

---

## 11. The quality discipline that made the exemplars good

The build recipe above is necessary, not sufficient. The process rules —
each one bought with a specific failure in this workspace:

- **Build the hostile fixture first.** For anything touching the filesystem,
  create the actual junction / dangling link / hardlink / hidden directory
  *before* writing the code, and write against it. Every serious defect that
  survived self-review here *looked right and was self-consistent*; only the
  real object exposed it.
- **Verification must enumerate from the other side.** A test that iterates
  *your own* list of things can only find disagreements about what you already
  know; it is structurally blind to what is missing. (A "273/273 agree" gate
  here hid four missing tools for a month.) The same blindness applies in
  time: a green gate says nothing about the code you just added — machteld's
  history is emphatic that gates catch regressions and only *applications*
  find the defects in new work.
- **Adversarial review finds what self-review cannot.** Independent reviewers
  with briefs to *break* the code found — in one pass — a heap over-read with
  a working PoC, a per-call leak, and a safety layer defeated by a junction.
  Cheap to run with agents; run it on anything that deletes, writes, or parses.
- **The building agent verifies the GUI itself; the app carries its own
  probe; the camera aims at the window, not the screen.** External automation
  is not a valid driver for Tk (ph: SendKeys and UIA never validly drove its
  dialogs while `IsHungAppWindow` kept reporting healthy). So the app ships
  `--probe-*` flags that drive the scenario from inside — blad's
  `--probe-pdf` presses its own button and lights the status line; berg's
  `--probe-end` jumps a 100k-row list to its last row — and the agent
  photographs the result and *reads the photograph*. The photograph has its
  own bought rules: capture the app's window via
  `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)` — it renders the window
  even when occluded and steals no focus (a full-screen capture on a live
  machine once returned the user's browser instead of the app, which is both
  a wrong result and a privacy fault); make the capturing process DPI-aware
  (`SetProcessDPIAware`) or `GetWindowRect` returns virtualized coordinates
  and the bitmap silently crops at scaled DPI; and one-shot PowerShell
  hosts forget `Add-Type` types between invocations — redefine per call.
  Fixed sequence: console selftest → GUI selftest → launch with probe flag →
  window capture → read the image → kill by process name. The user's click
  is the last verification, never the first. (els's `cap` module applies the
  same API from inside an app; this rule is the agent outside it.)
- **This document's own fitness is measurable.** The luax project built the
  instrument: blind agents given only the manual, solving tasks graded
  against hidden references. That methodology is why "an agent given only
  this document" is a testable promise rather than a slogan — and ph, the
  d3d spike, and blok are live instances: each was built from this document
  by an agent, with the host compiling first-try once §12's traps were paid.
- **Keep a decision register; supersede, never silently edit.** drang's
  DESIGN.md tags every entry (`[LOCKED]`, `[SUPERSEDED]`) and prefaces the
  list with "the tag means *was* decided, not *is* current" — a sentence
  that saved this document's own authors from stale ground truth. X's
  register goes further: every decision names its evidence. Both practices
  transfer to any app old enough to have reversed itself.
- **When an app implements a spec, pin the official conformance suite as
  the oracle and hold the asymmetric property: zero false passes.** An
  over-report must be *refused by name*, never skipped silently — X's JSON
  Schema validator refuses 457 of 1299 cases each naming the unimplemented
  keyword, and kuu's regression-gated pass set applies the same law to a
  language runtime. A validator that quietly skips reports validity it
  cannot vouch for.
- **When two implementations must be proven equal, the proving run is also
  the measuring run.** reken's calibration executes both arms of a kernel
  on one sample: the comparison is the correctness oracle, and the two
  clocks around it are the routing ratio. One execution, two products —
  differential verification that pays its own way.
- **Fail closed, and refuse rather than approximate.** A dialog-and-exit on a
  damaged payload; a build that rejects a dirty tree; a packager that errors
  on a stale input rather than shipping it. A confident wrong artefact is
  strictly worse than a refusal that names what is missing.
- **Measurement rules** (each learned by publishing a wrong number first): an
  end-to-end number cannot measure a component smaller than its own variance;
  a ratio you cannot attribute is not a result; comparisons must be
  interleaved, not blocked; and beware the cold file cache — it has produced a
  10×-wrong "measurement" in this workspace five separate times.
- **Write the WHY into the code.** The documents and comments in els and
  machteld carry the failure mode next to every rule. That is not style — it
  is what lets the next agent (or you, in a year) distinguish load-bearing
  strangeness from incidental style, which is the difference between
  maintaining a codebase and re-earning its scars.

---

## 12. The C++ host — what ph proved

Proven 2026-08-16 by **ph**, a WIC photo viewer scaffolded from this document:
console twin, GUI host, fused exe, selftest and probe all green — full build
clean under `-Wall -Wextra -Werror`, g++ 16.1.0 (MSYS2 UCRT64), static
Tcl/Tk 9.0.4. The project was deliberately deleted the same day; what it
taught the method is kept here.

### The sanctioned C++ subset: C with destructors

When the host must speak COM (WIC, shell interfaces), write it in C++ — in
plain C every acquired interface needs a hand-paired `Release` and every
`PROPVARIANT` a `PropVariantClear` across every early-exit path, and at a few
hundred lines of decode/metadata code that is where leaks breed. The subset
that preserves the method's discipline:

- `g++` with the SAME load-bearing flags as §4, plus `-fno-exceptions
  -fno-rtti`; the link adds `-static-libstdc++`.
- Exactly two owned RAII types: a ~30-line `com_ptr<T>` (Release on scope
  exit, `put()` for out-params) and a `prop_variant` guard. No STL in the
  host, no `new`/`delete`; buffers via `Tcl_AttemptAlloc`.
- `extern "C"` on EVERY symbol looked up by name — `wWinMain`/`wmain`, the
  `_CRT_glob` data symbol, each `*_Init` the host registers. C++ mangling
  otherwise leaves the CRT unable to find the entry point.
- Everything in §3 unchanged: same AppHook, same damaged-exe refusal, same
  fail-via-MessageBox `InitFailure` (`[[noreturn]]` replaces `_Noreturn`).

When is C++ warranted at all? lunar (§13) does its COM in plain C via the
COBJMACROS interface — ~650 lines, a handful of interfaces, resources cached
once — and stays clean. ph's WIC surface (decode plus metadata writing,
PROPVARIANTs on every error path) is where hand-paired Release/Clear starts
breeding leaks. The calibration: a few interfaces holding long-lived cached
resources read fine as C; grow past that, or into per-call PROPVARIANT
traffic, and the two RAII types pay for themselves.

### The seams C++ exposes (invisible in C)

- **Tcl and Tk disagree about the wide char.** Tcl 9 declares its wide
  surface (`TclZipfs_AppHook`, `Tcl_MainExW`) as `unsigned short**`; Tk 9
  declares `Tk_MainExW` as `wchar_t**`. C converts both silently from the
  CRT's `wchar_t**`; C++ rejects each. Convert once per entry point (the
  types are ABI-identical on Windows) and keep using the pointer the AppHook
  hands back — it may rewrite argv.
- **mingw-w64's `wincodec.h` lags Windows.** The right downscale mode for a
  viewer, `WICBitmapInterpolationModeHighQualityCubic`, is missing from the
  header; supply the enumerator yourself (`(WICBitmapInterpolationMode)0x4`,
  stable ABI, Windows 10+). A WIC too old for it fails loudly at
  `Initialize`, never silently.
- WIC adds `-lwindowscodecs` to §4's closure (same rule as machteld's
  psapi/bcrypt/winhttp: add what the linker asks for), and
  `#include <initguid.h>` before `<wincodec.h>` in exactly one TU
  instantiates the GUIDs without `__uuidof`.

### Verification additions (extending §8)

- **The headless self-check must be fail-closed.** Wrap its whole body so ANY
  internal error still writes the report. ph's first selftest died on a Tcl
  slip before its report write: exit 1, no report — and in source mode the
  wish startup-error dialog, which is the only voice a `-mwindows` process
  has.
- **Ship a `--probe files...` mode beside `--selftest`**: run real inputs
  through the real pipeline, write timings + geometry + spot-checked pixels
  to a report, exit nonzero on any failure. This is the agent-facing test
  surface — real files exercised with no human clicking dialogs. (ph's
  probe: a 200×100 JPEG in 23 ms; 6000×4000 fit to 1350×900 in 226 ms; EXIF
  orientation 6 detected with dimensions swapped and pixel-verified.)
- **Generate hostile fixtures programmatically.** PowerShell +
  System.Drawing writes real JPEGs including EXIF orientation (construct the
  `PropertyItem` via `GetUninitializedObject`; id 0x0112, type 3, value 6).
  Make the fixture colors encode the expected answer: red-left/blue-right
  catches a channel-order swap; an edge stripe catches a wrong rotation.
- **Drive the built GUI from outside before any human does**: `Start-Process`
  + `.Responding` sampling + an env-gated trace file that narrates each
  step. The user's click is the last verification, never the first.
- **Known automation limit, recorded to save the next chase:** synthetic
  input (WScript `SendKeys`) and UIA patterns failed against Tk 9's native
  file dialog even while `IsHungAppWindow` reported the dialog healthy.
  Dialog flows need a real hand — design the probe mode so dialogs are never
  in the automated test path.

### Small Tcl traps hit along the way

- `[info script]` is EMPTY inside event callbacks — §7's "derive the state
  root once, at startup" is not style advice. ph derived it lazily and its
  own debug log silently vanished.
- Inside a proc whose namespace is `::ph`, `$ph::version` resolves
  `::ph::ph::version` — and unlike command names, variables get no global
  fallback. Declare `variable version` instead.
- Braces are not string literals inside a braced `expr`:
  `[expr {$x ? {a} : {b}}]` is a parse error; quote the strings.

---

## 13. Hardware rendering in a Tk widget — what lunar proved

Tk's canvas draws without antialiasing, and no amount of Tcl fixes that.
lunar (the analog clock; shipped, z-curated) proves the escape: a **custom Tk
widget class in C whose paint path is Direct2D**, sitting inside ordinary Tk
geometry management. The app packs `.face.clock` like any widget and drives
it through instance subcommands; C owns nothing but the pixels.

### The integration points (all from `src/lunarclock.c`)

- A class command (`lunarclock pathName ?options?`) creates the widget; the
  per-instance command is registered under `Tk_PathName(window)` and deleted
  on `DestroyNotify`.
- The render target comes from Tk's own window: `Tk_MakeWindowExist(tkwin)`,
  then `Tk_GetHWND(Tk_WindowId(tkwin))` feeds
  `ID2D1Factory::CreateHwndRenderTarget`.
- `Tk_CreateEventHandler(..., ExposureMask | StructureNotifyMask, ...)`
  routes Expose and ConfigureNotify to a redraw request; state changes arrive
  from Tcl through subcommands (`show`, `redraw`), so the application logic —
  what time it is, what trust state to display — never lives in C.
- Device-INdependent resources (the hands, cached as `ID2D1PathGeometry`)
  survive target loss; device-DEPENDENT ones (target, brush) are created and
  discarded together. That split is the discipline the API rewards.

### The traps, each paid for once

1. **Recreate the target on resize; do not `Resize` it.** A Tk layout pass
   moves and resizes the child HWND several times, and an in-place
   `HwndRenderTarget::Resize` left stale pixels beside the newly laid-out
   dial. Discard and recreate at the next paint — a resize-path-only cost.
2. **Check `EndDraw` for `D2DERR_RECREATE_TARGET`.** The device can vanish
   (driver reset, session change); the return code is the notification.
   Discard the device-dependent pair and rebuild on the next paint — which
   the resource split above makes a non-event.
3. **Never hold a lock across `EndDraw`.** It may flush the GPU command
   queue. lunar held a critical section across the present and stalled its
   NTP aggregator thread for hundreds of milliseconds under GPU load
   (`docs/known-issues.md` §2, resolved). The replacement pattern: snapshot
   shared state under the lock, present without it, and validate a generation
   counter immediately before and after `EndDraw` — a stale frame then
   survives at most one repaint.
4. **The degrade path is mandatory** (§8): lunar gates on
   `[llength [info commands ::lunarclock]]` and falls back to a plain canvas
   clock, which is what keeps the `wish90` source-mode loop alive without
   the native module.

### Boundaries

- Toolchain-pure: mingw-w64 ships the headers and import lib; `-ld2d1` joins
  the closure the §4 way. (lunar also links `-ldwrite`; nothing uses it —
  the dial renders no DirectWrite text, and this document claims nothing
  about text.)
- DPI stays governed by §5: system-DPI-aware, scaling owned by the system.
  The widget carries no per-monitor DPI code, and under §5's manifest stance
  it needs none.
- lunar's COM is plain C via COBJMACROS — see §12's calibration for when
  that stops being the right call.

### The door, walked: Direct3D (proven by the d3d spike, 2026-08-16)

An earlier revision called D3D "the same door, unwalked." A one-day spike —
a Tk widget whose paint is a D3D11 swapchain, rendering a shader-drawn
triangle inside a fused one-exe — walked it, and the transposition held
exactly: the swapchain is created on `Tk_GetHWND(Tk_WindowId(...))`; the
RTV must be released **before** `IDXGISwapChain::ResizeBuffers` (the D3D
spelling of "recreate, don't Resize"); and `Present`'s HRESULT carries
device loss (`DXGI_ERROR_DEVICE_REMOVED`/`_RESET`) precisely as
`D2DERR_RECREATE_TARGET` does for D2D. Hardware device at feature level
11_0, ~1,370 uncapped frames/s at 480×360, WARP fallback reported honestly,
`ResizeBuffers` re-probed after a live resize.

What the walk added that the D2D section had not said:

- **The widget TU inverts the host's include order.** The §3 host includes
  `tk.h` first; a widget TU must include `windows.h` FIRST and then
  `tkPlatDecls.h` explicitly, or `Tk_GetHWND` is silently never declared
  (lunar's files always did this; this document had not said so until the
  spike, built from the document alone, hit it).
- **`DXGI_SWAP_EFFECT_DISCARD` leaves the backbuffer undefined after
  `Present`** — a pixel probe must copy to its staging texture BEFORE
  presenting.
- **The default rasterizer culls counter-clockwise faces, and the first
  triangle everyone writes is counter-clockwise.** It renders as pure
  nothing. The spike's pixel probe caught it in one run; an eyeballed demo
  would have seen an animated clear color and called it success — §12's
  probes-before-eyeballs rule, vindicated in the most literal way available.
- **A struct holding RAII members is placement-new'd into `Tcl_Alloc`
  storage and destroyed explicitly** — `memset` on it is
  `-Werror=class-memaccess`, and the compiler is right.

One meta-result worth its line: the spike's host and console twin compiled
first-try with zero seam errors, from this document alone — §12's traps,
paid once by ph, stayed paid.

---

## 14. Networking, and the third-party-library door — what lunar and reken proved

lunar ships NTS-secured time sync, and doing so proved two things at once.

**A vendored C library onboards cleanly.** lunar carries the complete
**mbedTLS 3.6.6 source tree** under `third_party/` (Apache-2.0; LICENSE
retained, notices obligation applies per §6), configured by lunar's OWN
header (`-DMBEDTLS_CONFIG_FILE=<lunar_mbedtls_config.h>` — the library
compiles only what the app needs), built into an archive by the build script
and statically linked beside the Tcl libraries. That is the recipe: vendor
the source, own the config, build an archive, link it, carry the notice.
"License-apt C libraries can join the exe" is not a hope; lunar is the
existence proof.

**The TLS design worth copying.** TLS 1.3 runs over plain SOCKETs through
mbedTLS/PSA; trust is a hybrid: **Windows' own certificate-chain and
hostname policy APIs** (`wincrypt`, `-lcrypt32`) decide Web-PKI validity, and
an **SPKI SHA-256 pin** (constant-time compared) decides continuity. Link
additions beyond §4's closure: `-lcrypt32 -lbcrypt`.

**The trap, paid in design review** (lunar `docs/known-issues.md` §1):
**hardcoded pins are a scheduled outage** — when the provider rotates keys,
every shipped binary rejects the new certificate until rebuilt. The shipped
fix: the exe carries endpoint metadata only; on first run (and on renewal or
expired-pin recovery) it validates through the OS trust store, captures the
leaf SPKI, and stores it per-user under DPAPI with a strict ACL. Pins are
runtime-enrolled state, never compiled-in material. Exercise first-run
enrollment on a clean profile before any release.

**The door admits language runtimes (what reken proved).** The reken spike
(2026-08-19, `C:\dev\_reken`) vendored the complete **Lua 5.5.0** source
(MIT; 32 C files, the `lua`/`luac` frontends excluded) into a console host
by the same recipe: **+271 KB of exe for a whole interpreter**, opened with
only base/string/math/table — no `io`, no `os` — and metered into a cell:
a counting allocator enforces a hard memory cap, a count hook enforces an
instruction budget, and both were proven by hostile fixtures (a memory bomb
and a runaway loop, each dying cleanly). Two laws came with the door:
**compile C-heritage runtimes as C, never as C++** — Lua's errors are
`longjmp`, and a C++ compile turns them into exceptions against this
discipline's `-fno-exceptions` — and §10 trap 18's allocator law. (Lua 5.5
notes: `lua_newstate` takes an explicit hash seed; `onelua.c` is gone —
compile the objects.) With the door open this far, §1's division of labour
gains a measured middle tier: Tcl orchestrates, C substrates, and
**generated code in an embedded VM** runs between them. reken's ladder on
a 1M-row arithmetic aggregate: interpreted AST 1×, generated Tcl ≈10×,
generated Lua ≈45×, sharded-parallel Lua ≈200× — with the marshal
(~0.7 s/1M rows into the VM) as the tax that decides when the tier pays,
and every number registered as a prediction before it was measured.

---

## 15. The rest of the harvest

Five capabilities the estate paid for before this page carried them.

### Explorer drag-and-drop (els, `src/windrop.c`)

`DragAcceptFiles` on the Tk toplevel's HWND plus a comctl32
`SetWindowSubclass` whose `WM_DROPFILES` branch reads the dropped paths.
The load-bearing rule: **the subclass proc never evaluates Tcl inline** —
window-message dispatch may be nested inside a running Tcl command (an
`update`), so it collects the paths, `Tcl_QueueEvent`s them, and returns;
the handler runs at a safe point in the event loop. The subclass removes
itself on `WM_NCDESTROY`. Links `-lcomctl32 -lshell32`; built in both §8
modes (dev DLL, static product).

### Seeing a GUI without a screen (els, `src/cap.c` + `tools/shot.tcl`)

The missing half of §12's probes-before-eyeballs: actual eyes, headless.
`elscap::run_private` creates a **private Win32 desktop** (`CreateDesktopW`,
never passed to `SwitchDesktop`, so nothing ever flashes on the user's
screen), starts one suspended child there, assigns it to a kill-on-close
Job, resumes, and waits bounded. The child Tk app maps and paints normally
on that desktop and captures its own toplevel with
`PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)` into a DIB; Tcl converts to
PNG. Two details that bit: `PW_RENDERFULLCONTENT` needs a fallback
`#define` (mingw-w64 header lag, §12's recurring character), and foreground-
window equality is asserted around the capture so a stolen focus fails the
run instead of poisoning the shot.

### Threads — present, and honestly bounded

The workspace payload ships **Thread 3.0.6** (`tcl9thread306.dll` +
pkgIndex, in both the shared and static trees). Proven: `package require
Thread` under the payload's tclsh/wish (the X project's parallel substrate
runs on it). **Unproven: Thread inside a fused one-exe** — a DLL cannot be
loaded from `//zipfs:` without first being copied out to disk, and no
application in this estate has done either. Until one does, a fused exe
should be written single-threaded (native modules may thread internally —
lunar's NTP aggregator does — under §13's lock discipline).

### In-process compute threads (reken's parallel pool)

The first proven thread-parallelism *inside* a fused exe — at the C level,
where the paragraph above does not bind. N fully independent embedded-VM
states on N `_beginthreadex` workers; rows sharded contiguously at marshal
time; one kernel compiled into every state; integer partials reduced
afterwards (the aggregates are monoids, so the reduce is arithmetic, not
cleverness). What makes it safe is ownership, not locks: **workers touch
only their own state, and every Tcl_Obj stays on the main thread** —
sharding is therefore serial by necessity, results cross as plain structs,
and a failing worker reports its slot by name. Measured 2026-08-19:
scaling tops out at 4–6× on 12 logical cores (the memory-bandwidth wall
arrives before the core count does) — and shards accelerate what the VM
cannot: C-loop-bound string work gained 6× from parallelism where the VM
alone gained nothing. The two mechanisms are complementary, not redundant.

### Vendored datasets

Two proven shapes: ordinary payload files under `//zipfs:/app/resources`
(els), and — for data needed independent of the mount — generated C arrays
(lunar embeds tzdata and CLDR's `windowsZones.xml` via `tz_embed`, licenses
retained under `third_party/`). Prefer the payload; embed in C only with a
reason.

---

## 16. Children — the no-orphans law (what machteld, els, and one live incident proved)

An application that launches child processes must give every child a
**decided lifetime**, and the default is: children die with the app. On
Windows the mechanism is the Job Object, and the estate holds three
independent implementations that agree (machteld `src/winjob_job.c` and
`src/winjob_launch.c` in C; els `src/cap.c`'s capture harness in C; drang's
`internal/winjob` in Go).

The recipe, from machteld's C:

- `CreateJobObjectW(NULL, NULL)` — NULL attributes, so the handle is
  non-inheritable — then `SetInformationJobObject` with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. When the last job handle closes —
  including because your app exited or crashed — the kernel kills the whole
  tree. Whole-tree kill on demand is `TerminateJobObject`. On modern
  Windows, children of children join the job automatically; the tree is
  covered without further ceremony.
- **Assign before the child runs** (els `cap.c`): create the child
  `CREATE_SUSPENDED`, `AssignProcessToJobObject`, then `ResumeThread`. A
  child assigned after it starts can spawn a grandchild in the gap.
- **Escape is a decision, never a default** (machteld `winjob_launch.c`):
  a child meant to outlive the app breaks away explicitly —
  `JOB_OBJECT_LIMIT_BREAKAWAY_OK` on the job,
  `CREATE_BREAKAWAY_FROM_JOB | CREATE_SUSPENDED` at launch — and machteld
  preserves `KILL_ON_JOB_CLOSE` for everything that did not break away.

**The trap, paid live on 2026-08-16:** spac's `z run` task launched its
game with `exec wish ... &` and exited. Under z's supervision the "detached"
child died within a second, every time — because z kills the task's process
tree on completion, by exactly this law; the same wish launched
unsupervised runs fine. The rule: *detaching is not a lifetime policy.*
Under a supervisor, outliving the task requires the supervisor's blessing;
inside your own app, a child either joins the job or has a written reason
not to. A "launcher" task under a tree-killing supervisor must stay alive
for its child's lifetime, or hand the launch to something that does.

---

## 17. The exe that carries its own manual (what machteld proved)

machteld's payload embeds the **complete, exact-version reference corpus**
— its own manual plus the Tcl 9 and Tk 9 documentation — and the running
exe exposes it: `docs status / schema / verify / list / get / outline /
search / extract`, JSON-friendly, never consulting the network or a
machine-wide documentation install. The argument is the same one that
justifies the static runtime (§1): the app can never meet a *different
manual* than the one it was built and tested with.

The method form is small: the payload already carries `tcl_library`; a
`docs/` tree beside it plus a `--docs` (or subcommand) surface makes the
exe self-describing. This matters most for the reader this document
assumes — an agent picking up the binary cold: "which version's docs" stops
being a failure class, and `docs verify` gives the corpus an integrity
check in the same spirit as the damaged-exe refusal.

Related, smaller, listed not specified: machteld's `wrap` turns packaging
itself into a runtime verb — the shipped exe can stamp new exes — an
alternative shape for §6 when a tool's job includes producing tools.

---

## 18. The second harvest — sound, streams, hotkeys, icons (spac, rae, ann)

Three more app-proven capabilities, mined after the first harvest missed
their owners.

### Sound, two proven tiers

- **The PlaySound tier** (spac, `src/invaders.c`): effects are *synthesized
  once into in-memory WAV buffers* and played with `PlaySound(SND_ASYNC)` —
  single-voice, newest-wins, and deliberately **silent under test-step**, so
  determinism survives the sound. `-lwinmm`, ~zero code weight; right for
  blips and games.
- **The WASAPI tier** (rae, `src/rae_tuner.c` and friends): real streaming
  playback in C — WASAPI opened lazily, **drain-then-reopen on format
  change**, fed through an SPSC ring from a tuner thread, RMS metered.
  Upstream of it, a full internet-radio stack: HTTP leg detection by
  Content-Type plus first-bytes sniff, ICY metadata de-interleaving
  (stream titles), MP3/ADTS progressive and HLS legs, and a
  reconnect-forever backoff ladder. rae's own `CONTRACTS.md` is the spec;
  this document records that the entire tier exists in-estate, in C, in a
  shipped app. rae also proves **Tcl's bundled sqlite3 package used in-app,
  with FTS5** (its station directory) — noting that §2's minimal recipe
  deliberately skips bundled packages, so a runtime built for an app that
  wants SQLite must build and stage it too.
- The capture half of audio remains unwalked; §19 applies.

### The global hotkey (ann, `src/annhotkey.c`)

The trap, paid and documented at the source: **Tk owns the GUI thread's
Win32 message pump, and a thread-targeted `WM_HOTKEY` can be swallowed
before your code sees it.** The robust pattern: a *dedicated hotkey thread*
owning a message-only HWND — so `WM_HOTKEY` arrives at a WndProc you
control — with `RegisterHotKey(... | MOD_NOREPEAT)` called on the thread
that owns the window, rebinds marshalled to that thread as thread messages,
and delivery into Tcl via `Tcl_ThreadQueueEvent` + `Tcl_ThreadAlert` — the
cross-thread edition of §15's queue-never-eval rule. ann's single-instance
"show" forwarding rides the same channel.

### Icons into Tk (ann, `src/annicon.c`)

The read-side sibling of ph's WIC module: an HICON → RGBA → `Tk_Photo`
pipeline entirely in C, with a C-side LRU cache. One command fills a named
photo from a spec: a path (`IShellItemImageFactory::GetImage`, falling back
to `SHGetFileInfo`), `aumid:` for packaged apps via `shell:AppsFolder`,
`hwnd:` for a live window's own icon, `stock:` for the system set. The
division holds: *Tcl names a photo; the UI never touches HICONs or pixel
formats.*

---

## 19. The boundary, written down

What this document does NOT claim, so nobody reads a promise into silence:

- **Large C++ libraries are unproven.** mbedTLS proves C-scale vendoring;
  nothing of the whisper.cpp/ONNX class — C++ with exceptions/RTTI
  expectations and heavyweight builds against this `-fno-exceptions`
  discipline — has been onboarded. The first application that needs one
  buys this section, or discovers its limits.
- **Thread in a fused exe** — see §15; bounded until an application proves
  the copy-out-and-load path. (C-level worker threads are proven — §15's
  parallel pool; the bound is on Thread-the-extension.)
- **Runtime code generation stops at the embedded VM.** Generated Lua is
  proven (§14); **runtime C compilation is refused for shipped
  applications** — it assumes a compiler on the user's machine, which only
  the z workspace guarantees. A factory living inside the workspace may
  compile at run time; an exe on a stranger's laptop may not, and no
  application design may quietly assume otherwise.
- **Audio capture** — playback is proven twice over (§18); the microphone
  side has no exemplar yet.
- **DirectWrite text** — linked by lunar, used by nothing; §13 stands.
- **WebView2 is refused on principle**, not omitted by accident: it
  requires its own installed, self-updating runtime, which breaks the one
  promise this method exists to keep. An application that needs web
  rendering is a different kind of application; build it on a different
  method.

---

*Provenance: distilled 2026-08 from `els` (host `src/els_main.c`; build
`tools/tasks.tcl`; packaging `tools/package.tcl`; resources `tools/genres.tcl`;
`toolchain.md`) and from `machteld` (from-source runtime recipe
`tools/bootstrap-deps.sh` + `tools/dependencies.lock.json`; the §10 filesystem
and process traps were measured during its development, 2026-08-10..13). The
els-specific z-workspace tooling was deliberately removed: everything above
assumes only MSYS2 and the upstream Tcl/Tk 9.0.4 sources. §12 and trap 16
were proven 2026-08-16 by `ph`, a WIC photo-viewer scaffold built from this
document and deliberately deleted the same day — the method keeps what the
project learned. §13 is extracted from `lunar` (the widget
`src/lunarclock.c`; the lock-across-EndDraw incident `docs/known-issues.md`
§2), a shipped, z-curated application; its Direct3D subsection was proven
2026-08-16 by the `d3d` spike (`C:\dev\_d3d`), built from this document
alone and verified by pixel readback. §14–§15 are a harvest pass
(2026-08-16) over capabilities the estate had already paid for — lunar's
mbedTLS/Web-PKI/pinning stack and vendored datasets, els's `windrop.c` and
`cap.c` — and §19 records what remains unproven or refused, so the
document's silences cannot be mistaken for promises. The second harvest
(§18, same day) mined spac's synthesized-WAV PlaySound tier, rae's
WASAPI/ICY streaming stack and in-app SQLite+FTS5, and ann's hotkey-thread
and icon pipelines; §11 gained three discipline entries from the language
line (luax's blind-agent fitness instrument; drang's and X's decision
registers; X's and kuu's zero-false-passes oracles). The same day's
machteld/drang harvest added §16 (the no-orphans law: machteld
`src/winjob_job.c`/`winjob_launch.c` and els `cap.c` as the C proofs,
drang `internal/winjob` corroborating, the spac incident as the live
trap) and §17 (machteld's embedded, queryable documentation corpus), and
sharpened §11 with machteld's hardest-won sentence: gates catch
regressions; only applications find the defects in new work. §11's
GUI-verification law and §10 trap 17 were bought 2026-08-18 by `berg`
(`C:\dev\_berg`), the virtual-list explorer spike. The third harvest
(2026-08-19) came from the `reken` spike (`C:\dev\_reken`), which vendored
Lua 5.5 behind a metered bridge and measured a four-tier execution ladder
with predictions registered before every number: §14's language-runtime
extension and cell, §15's in-process parallel pool, §10 trap 18, §11's
proving-run-is-measuring-run, and §19's runtime-codegen boundary. §10 traps
19–24, with §3's payload pinning and the matching corrections to §4, §6 and
§7, were bought 2026-09-25 by `vanisha` (`_vanisha`), the NIS operator list
rebuilt onto this method from Python/PyInstaller: the library override was
measured against the static 9.0.4 runtime and then on a fused exe among
decoy libraries, where the pinless host read or ran four of them; the
`Tk_Main` dialog was met live and traced to `tkWinInit.c`; the `strip` stamp
was found by comparing two builds of one tree and traced through binutils'
`objcopy.c` and `bfdio.c`; the Treeview padding was isolated with
controlled treeviews captured on a private desktop; and the redesign that
followed timed its flat headings on the fused exe, tracing the cost to
`Ttk_Fill`, and found the borrowed field's ring in a 1:1 capture.*
