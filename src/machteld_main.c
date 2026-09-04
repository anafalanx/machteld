/* Windows console host for opted-in programs and the interactive REPL.
 * It requires a Unicode, static Tcl/Tk build so AppHook can self-mount zipfs. */
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
 * TclZipfs_AppHook self-mount the zip appended to this executable, then hand off to
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

    /* These switches belong to the runtime executable, not to tools made
     * with `wrap`.  AppHook has now told us whether this executable carries an
     * embedded main.tcl, so wrapped programs receive their own --help and
     * --version arguments unchanged. */
    Tcl_Obj *startup = Tcl_GetStartupScript(NULL);
    if (startup == NULL && argc >= 2 &&
            _tcscmp(argv[1], _T("--docs")) == 0) {
        /* Tcl_Main needs a startup-shaped word in order to preserve the
         * remaining words as $argv until AppInit dispatches the host route.
         * The replacement is shorter than the writable CRT argument buffer. */
        _tcscpy(argv[1], _T("docs"));
        Machteld_SetHostMode(MACHTELD_HOST_DOCS);
    } else if (startup != NULL && argc >= 2 &&
            _tcscmp(argv[1], _T("--machteld-docs")) == 0) {
        /* A wrapped application owns every ordinary argument.  This one
         * deliberately names the embedded runtime, so remove only the escape
         * word and pass its tail to ::machteld::DocsHost. */
        for (int i = 1; i + 1 < argc; i++) {
            argv[i] = argv[i + 1];
        }
        argc--;
        argv[argc] = NULL;
        Machteld_SetHostMode(MACHTELD_HOST_DOCS);
    } else if (startup == NULL && argc == 2 &&
            _tcscmp(argv[1], _T("--help")) == 0) {
        Machteld_SetHostMode(MACHTELD_HOST_HELP);
        argc = 1;
    } else if (startup == NULL && argc == 2 &&
            _tcscmp(argv[1], _T("--version")) == 0) {
        Machteld_SetHostMode(MACHTELD_HOST_VERSION);
        argc = 1;
    } else if (startup == NULL && argc >= 2 &&
            _tcscmp(argv[1], _T("-encoding")) == 0) {
        Machteld_SetHostMode(MACHTELD_HOST_ENCODING);
    } else if (startup == NULL && argc >= 2 &&
            _tcscmp(argv[1], _T("-")) == 0) {
        Machteld_SetHostMode(MACHTELD_HOST_STDIN);
    }

    Tcl_Main(argc, argv, Machteld_AppInit);
    return 0; /* Tcl_Main does not return; silences a warning. */
}

/*
 * Machteld_AppInit -- console per-interpreter init: Tcl core, Tk registered as a
 * static package for on-demand loading, then register the native libraries and
 * prelude.
 */
static int
Machteld_AppInit(
    Tcl_Interp *interp)
{
    if (Machteld_PreInit(interp) != TCL_OK) {
        Machteld_Fatal(interp);
    }
    if (Tcl_Init(interp) == TCL_ERROR) {
        Machteld_Fatal(interp);
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
    if (Machteld_RegisterLibs(interp) != TCL_OK) {
        Machteld_Fatal(interp);
    }
    return TCL_OK;
}
