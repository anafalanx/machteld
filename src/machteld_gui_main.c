/* Windows GUI host for wrapped tools. It requires a Unicode, static Tcl/Tk
 * build and an embedded main.tcl selected by AppHook. */
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
static int init_tk_preserving_args(Tcl_Interp *interp);

/*
 * _tWinMain -- GUI entry (WinMain under -municode). Normalize argv[0], let
 * TclZipfs_AppHook self-mount the appended zip (which registers the
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

    /* Engine mode leaves before any Tcl, Tk, or zipfs work; a GUI-subsystem
     * exe spawned with pipes serves protocol 1 exactly like the console
     * host, so wrapped GUI tools carry their engine in their own file. */
    if (argc >= 2 && _tcscmp(argv[1], _T("--machteld-engine")) == 0) {
        int engineThreads = (argc >= 3) ? (int)_tcstol(argv[2], NULL, 10) : 0;
        return Machteld_EngineMain(engineThreads);
    }

#if defined(UNICODE)
    TclZipfs_AppHook(&argc, &argv);
#endif

    /* Wrapped applications own their command line except for this explicit,
     * namespaced runtime-introspection escape.  Keep Tk-looking arguments and
     * every other spelling untouched. */
    if (Tcl_GetStartupScript(NULL) != NULL && argc >= 2 &&
            _tcscmp(argv[1], _T("--machteld-docs")) == 0) {
        for (int i = 1; i + 1 < argc; i++) {
            argv[i] = argv[i + 1];
        }
        argc--;
        argv[argc] = NULL;
        Machteld_SetHostMode(MACHTELD_HOST_DOCS_GUI);
    }

    /*
     * Refuse to run as a bare Tcl-script host. If the appended payload did NOT
     * mount (a stripped/corrupt exe), TclZipfs_AppHook registered no startup
     * script, and Tk_Main would fall back to wish semantics and source the first
     * file argument -- a double-clicked "document" would then execute arbitrary
     * Tcl. A packaged tool always registers its main.tcl here, so this only fires
     * on a damaged binary.
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
init_tk_preserving_args(Tcl_Interp *interp)
{
    Tcl_Obj *argv = Tcl_GetVar2Ex(interp, "argv", NULL, TCL_GLOBAL_ONLY);
    Tcl_Obj *argc = Tcl_GetVar2Ex(interp, "argc", NULL, TCL_GLOBAL_ONLY);
    if (argv == NULL || argc == NULL) {
        return Machteld_EntryError(interp, "state",
            "host application arguments are unavailable before Tk initialization");
    }

    Tcl_Obj *saved_argv = Tcl_DuplicateObj(argv);
    Tcl_Obj *saved_argc = Tcl_DuplicateObj(argc);
    Tcl_IncrRefCount(saved_argv);
    Tcl_IncrRefCount(saved_argc);

    int status = Tk_Init(interp);
    Tcl_InterpState tk_state = Tcl_SaveInterpState(interp, status);

    int argv_ok = Tcl_SetVar2Ex(interp, "argv", NULL, saved_argv,
        TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG) != NULL;
    int argc_ok = Tcl_SetVar2Ex(interp, "argc", NULL, saved_argc,
        TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG) != NULL;
    Tcl_DecrRefCount(saved_argv);
    Tcl_DecrRefCount(saved_argc);

    if (!argv_ok || !argc_ok) {
        Tcl_DiscardInterpState(tk_state);
        return Machteld_EntryError(interp, "state",
            "cannot restore application arguments after Tk initialization");
    }
    return Tcl_RestoreInterpState(interp, tk_state);
}

static int
Machteld_GuiAppInit(
    Tcl_Interp *interp)
{
    if (Machteld_PreInit(interp) != TCL_OK) {
        Machteld_Fatal(interp);
    }
    if (Tcl_Init(interp) == TCL_ERROR) {
        Machteld_Fatal(interp);
    }
    if (Machteld_GetHostMode() == MACHTELD_HOST_DOCS_GUI) {
        /* Runtime documentation is a headless control route even in a GUI
         * wrapper.  Make Tk available exactly as the console host does, but do
         * not create a transient root window merely to answer a query. */
        Tcl_StaticLibrary(NULL, "Tk", Tk_Init, Tk_SafeInit);
    } else {
        if (init_tk_preserving_args(interp) != TCL_OK) {
            Machteld_Fatal(interp);
        }
        Tcl_StaticLibrary(interp, "Tk", Tk_Init, Tk_SafeInit);
    }

    /* Native libraries + the prelude are shared with the console host. */
    if (Machteld_RegisterLibs(interp) != TCL_OK) {
        Machteld_Fatal(interp);
    }
    return TCL_OK;
}
