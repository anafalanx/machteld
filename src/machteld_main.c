/*
 * machteld_main.c -- Windows console entry point for machteld.
 *
 * machteld is a single signed exe: a C host with statically-linked Tcl/Tk 9 and
 * an appended zipfs (the Tcl prelude + the Tcl/Tk script libraries). Unlike the
 * els/sturm GUI starpacks this host is CONSOLE-subsystem and runs Tcl_Main, so
 * machteld behaves like a branded tclsh -- run a script, or drop into an
 * interactive REPL -- with the machteld palette preloaded and Tk available on
 * demand. Native capability (process control, the SQLite store, ...) accretes
 * here in C and is exposed as Tcl commands; there are no loadable DLLs.
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

#if defined(__GNUC__)
int _CRT_glob = 0; /* keep the mingw CRT from glob-expanding argv */
#endif

#ifdef MACHTELD_STATIC_SQLITE
extern int Machteldstore_Init(Tcl_Interp *interp); /* src/store.c */
#endif

#ifdef MACHTELD_PROC
extern int Machteldproc_Init(Tcl_Interp *interp); /* src/proc.c */
#endif

static int Machteld_AppInit(Tcl_Interp *interp);

/*
 * _tmain -- console entry (wmain under -municode). Mirrors Tcl's win/tclAppInit.c:
 * normalize argv[0], let TclZipfs_AppHook self-mount the zip appended to THIS
 * exe, then hand off to Tcl_Main. argv[1..] reach the interpreter as $argv.
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
 * Machteld_AppInit -- per-interpreter init: Tcl core, Tk registered as a static
 * package (loaded on demand, not now), machteld's native C libraries, then the
 * Tcl prelude from the appended zipfs.
 */
static int
Machteld_AppInit(
    Tcl_Interp *interp)
{
    if (Tcl_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }

    /*
     * Tk on demand: register the static Tk library with interp = NULL -- it is
     * available to load but NOT marked loaded and NOT initialized here, so a
     * script pulls a GUI up in-process only when it wants a cockpit (via
     * `load {} Tk`, or `package require Tk` as wired in the prelude). machteld is
     * a console shell first; nothing creates a window at startup. Passing a real
     * interp here would mark Tk "loaded" without initializing it, and the later
     * on-demand load would then no-op -- hence NULL.
     */
    Tcl_StaticLibrary(NULL, "Tk", Tk_Init, Tk_SafeInit);

#ifdef MACHTELD_STATIC_SQLITE
    /*
     * machteld's purpose-built SQLite bridge (src/store.c + the statically
     * compiled amalgamation), exposed as the curated ::machteld::store command
     * -- the C tier owns SQLite; not the generic sqlite3 extension, and no DLL.
     */
    if (Machteldstore_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldstore", Machteldstore_Init, NULL);
#endif

#ifdef MACHTELD_PROC
    /*
     * machteld's process-control substrate: the root Job Object plus
     * ::machteld::run (supervised exec -- born-in-job, tree-kill, limits, capture).
     */
    if (Machteldproc_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldproc", Machteldproc_Init, NULL);
#endif

    /*
     * Load the machteld prelude from the appended zipfs (mounted by AppHook).
     * It is named machteld.tcl, NOT main.tcl, so AppHook does not auto-run it as
     * the startup script: control returns to Tcl_Main, which then runs a user
     * script argument or drops into the interactive REPL -- a branded tclsh with
     * the palette preloaded. The mount point is discovered from `zipfs mount`
     * rather than hardcoded, so the layout stays the single source of truth.
     */
    static const char *bootstrap =
        "namespace eval ::machteld {}\n"
        "set ::machteld::prelude {}\n"
        "catch {\n"
        "  foreach _m [dict keys [zipfs mount]] {\n"
        "    if {[file exists $_m/machteld.tcl]} {\n"
        "      set ::machteld::prelude $_m/machteld.tcl; break\n"
        "    }\n"
        "  }\n"
        "}\n"
        "if {$::machteld::prelude eq {}} {\n"
        "  foreach _d {//zipfs:/app //zipfs:/} {\n"
        "    if {[file exists $_d/machteld.tcl]} {\n"
        "      set ::machteld::prelude $_d/machteld.tcl; break\n"
        "    }\n"
        "  }\n"
        "}\n"
        "if {$::machteld::prelude ne {}} {\n"
        "  uplevel #0 [list source $::machteld::prelude]\n"
        "}\n";
    if (Tcl_EvalEx(interp, bootstrap, -1, TCL_EVAL_GLOBAL) == TCL_ERROR) {
        return TCL_ERROR;
    }

    return TCL_OK;
}
