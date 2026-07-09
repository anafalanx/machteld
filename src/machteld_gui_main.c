/*
 * machteld_gui_main.c -- Windows GUI (no-console) entry point for machteld tools.
 *
 * The sibling of machteld_main.c: the same statically-linked Tcl/Tk 9 and the
 * same appended-zipfs self-mount, but GUI-subsystem (WinMain, -mwindows) so a
 * windowed tool packaged on this bare shows no console window. It runs Tk_Main --
 * Tk is initialized up front (a GUI tool always wants it) -- and the tool's
 * main.tcl in the appended archive is the startup script. The native libraries
 * and the prelude come from the SHARED Machteld_RegisterLibs (machteld_appinit.c),
 * identical to the console host: the two bares differ ONLY here, in entry point
 * and PE subsystem.
 *
 * Modeled on Tk's win/winMain.c (the source of wish90s.exe) and els_main.c, the
 * lineage's proven GUI starpack host.
 *
 * Build: -municode -DUNICODE -D_UNICODE -DSTATIC_BUILD=1 -mwindows;
 *        USE_TCL_STUBS undefined (else Tk_Main is a TIP-596 thunk that
 *        LoadLibrary's tcl90.dll and crashes in a static exe).
 */
#undef USE_TCL_STUBS
#include "tk.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#undef WIN32_LEAN_AND_MEAN
#include <locale.h>
#include <tchar.h>
#include "machteld.h"

#if defined(__GNUC__)
int _CRT_glob = 0; /* keep the mingw CRT from glob-expanding argv */
#endif

static int Machteld_GuiAppInit(Tcl_Interp *interp);

/*
 * _tWinMain -- GUI entry (WinMain under -municode). Normalize argv[0], let
 * TclZipfs_AppHook self-mount the zip appended to THIS exe (which registers the
 * tool's main.tcl as the startup script), then hand off to Tk_Main.
 */
int APIENTRY
_tWinMain(
    HINSTANCE hInstance,
    HINSTANCE hPrevInstance,
    LPTSTR lpszCmdLine,
    int nCmdShow)
{
    TCHAR **argv;
    int argc;
    TCHAR *p;
    (void)hInstance;
    (void)hPrevInstance;
    (void)lpszCmdLine;
    (void)nCmdShow;

    setlocale(LC_ALL, "C");

    /* Args from the CRT (wide under -municode); ignore lpszCmdLine. */
    argc = __argc;
    argv = __targv;

    for (p = argv[0]; *p != '\0'; p++) {
        if (*p == '\\') {
            *p = '/';
        }
    }

#if defined(UNICODE)
    TclZipfs_AppHook(&argc, &argv);
#endif

    /*
     * Refuse to run as a bare Tcl-script host. If the appended payload did NOT
     * mount (a stripped/corrupt exe), TclZipfs_AppHook registered no startup
     * script, and Tk_Main would fall back to wish semantics and SOURCE the first
     * file argument -- a double-clicked "document" would then execute arbitrary
     * Tcl. A packaged tool always registers its main.tcl here, so this only fires
     * on a damaged binary. (Carried from els_main.c.)
     */
    if (Tcl_GetStartupScript(NULL) == NULL) {
        MessageBoxW(NULL,
            L"This machteld tool cannot start: its embedded application payload "
            L"is missing or corrupt (the executable may be damaged).",
            L"machteld", MB_ICONERROR | MB_OK);
        return 1;
    }

    Tk_Main(argc, argv, Machteld_GuiAppInit);
    return 0; /* Tk_Main does not return. */
}

/*
 * Machteld_GuiAppInit -- GUI per-interpreter init: Tcl, then Tk UP FRONT (this is
 * a windowed host), then the shared native libraries + prelude. No console and no
 * interactive REPL: a GUI tool runs its main.tcl and lives in its event loop.
 */
static int
Machteld_GuiAppInit(
    Tcl_Interp *interp)
{
    if (Tcl_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    if (Tk_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "Tk", Tk_Init, Tk_SafeInit);

    /* Native libraries + the prelude are shared with the console host. */
    return Machteld_RegisterLibs(interp);
}
