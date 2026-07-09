/*
 * machteld_main.c -- Windows CONSOLE entry point for machteld (the toolkit
 * itself, and any console tool packaged on it).
 *
 * machteld is a single exe: a C host with statically-linked Tcl/Tk 9 and an
 * appended zipfs (the prelude + the Tcl/Tk script libraries). This host is
 * CONSOLE-subsystem and runs Tcl_Main, so machteld behaves like a branded tclsh
 * -- run a script, or an interactive REPL -- with the palette preloaded and Tk
 * available on demand. Its sibling machteld_gui_main.c is the GUI-subsystem
 * (WinMain) host for windowed tools; both share Machteld_RegisterLibs
 * (machteld_appinit.c), which registers the native libraries and sources the
 * prelude -- so a new C library is added once and both hosts inherit it.
 *
 * Build flags that matter (carried from els/sturm, verified there):
 *   -municode -DUNICODE -D_UNICODE : _tmain is wmain; TclZipfs_AppHook uses the
 *                                    WCHAR signature -- without UNICODE the
 *                                    self-mount silently no-ops and the prelude
 *                                    is never found.
 *   -DSTATIC_BUILD=1               : tcl.h/tk.h must not mark symbols dllimport.
 *   USE_TCL_STUBS undefined        : with stubs, Tcl_Main/Tk_Init become TIP-596
 *                                    thunks that LoadLibrary tcl90.dll and crash
 *                                    in a static exe with no such DLL.
 *   (no -mwindows)                 : console subsystem -- machteld IS a shell.
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

static int Machteld_AppInit(Tcl_Interp *interp);

/*
 * _tmain -- console entry (wmain under -municode). Normalize argv[0], let
 * TclZipfs_AppHook self-mount the zip appended to THIS exe, then hand off to
 * Tcl_Main. argv[1..] reach the interpreter as $argv.
 */
int
_tmain(
    int argc,
    TCHAR *argv[])
{
    TCHAR *p;

    setlocale(LC_ALL, "C");

    for (p = argv[0]; *p != '\0'; p++) {
        if (*p == '\\') {
            *p = '/';
        }
    }

#if defined(UNICODE)
    TclZipfs_AppHook(&argc, &argv);
#endif

    Tcl_Main(argc, argv, Machteld_AppInit);
    return 0; /* Tcl_Main does not return; silences a warning. */
}

/*
 * Machteld_AppInit -- console per-interpreter init: Tcl core, Tk registered as a
 * static package (loaded on demand -- machteld is a console shell first, nothing
 * creates a window at startup), then the shared native libraries + prelude.
 */
static int
Machteld_AppInit(
    Tcl_Interp *interp)
{
    if (Tcl_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }

    /*
     * Tk on demand: register the static Tk library with interp = NULL -- available
     * to load but NOT initialized here, so a script pulls a GUI up in-process only
     * when it asks (via `load {} Tk`, or `package require Tk` as wired in the
     * prelude). Passing a real interp here would mark Tk "loaded" without
     * initializing it, and the later on-demand load would then no-op -- hence NULL.
     */
    Tcl_StaticLibrary(NULL, "Tk", Tk_Init, Tk_SafeInit);

    /* Native libraries + the prelude are shared with the GUI host. */
    return Machteld_RegisterLibs(interp);
}
