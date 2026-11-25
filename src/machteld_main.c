/* Windows console host for opted-in programs and the interactive REPL.
 * It requires a Unicode, static Tcl/Tk build so AppHook can self-mount zipfs. */
#undef USE_TCL_STUBS
#include "tk.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#undef WIN32_LEAN_AND_MEAN
#include <locale.h>
#include <tchar.h>
#include <stdio.h>
#include <stdlib.h>
#include "machteld.h"
#include "wintext.h"

#if defined(__GNUC__)
int _CRT_glob = 0; /* keep the mingw CRT from glob-expanding argv */
#endif

static int Machteld_AppInit(Tcl_Interp *interp);

/* Select a matching sibling of the actual process image. argv[0] and the
 * working directory are caller-controlled and cannot identify the host. */
static int
select_companion(void)
{
    WCHAR image[32768];
    DWORD length = GetModuleFileNameW(NULL, image, (DWORD)(sizeof(image) / sizeof(*image)));
    if (!length || length >= sizeof(image) / sizeof(*image)) {
        fputs("cannot resolve the Windows host image path\n", stderr);
        return TCL_ERROR;
    }
    WCHAR *base = wcsrchr(image, L'\\');
    base = base ? base + 1 : image;
    WCHAR *extension = wcsrchr(base, L'.');
    if (!extension || extension == base || _wcsicmp(extension, L".exe") != 0 ||
            _wcsicmp(base, L"machteld.exe") == 0) return TCL_OK;
    wcscpy(extension, L".tcl");
    DWORD attributes = GetFileAttributesW(image);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        DWORD error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return TCL_OK;
        fprintf(stderr, "cannot inspect the companion script (Windows error %lu)\n", error);
        return TCL_ERROR;
    }
    if (attributes & FILE_ATTRIBUTE_DIRECTORY) return TCL_OK;
    char *path = mt_wide_to_utf8(image, -1);
    if (!path) {
        fputs("cannot represent the companion script path in Tcl\n", stderr);
        return TCL_ERROR;
    }
    for (char *p = path; *p; ++p) if (*p == '\\') *p = '/';
    Tcl_SetStartupScript(Tcl_NewStringObj(path, -1), "utf-8");
    free(path);
    Machteld_SetHostMode(MACHTELD_HOST_COMPANION);
    return TCL_OK;
}

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

    /* Application arguments follow the selected program on the command line. */
    Tcl_Obj *startup = Tcl_GetStartupScript(NULL);
    /* A previously captured archive worker must still verify its supplied
     * generation, even if a sibling script was installed in the meantime. */
    if (!startup && !(argc >= 2 && _tcscmp(argv[1], _T("--machteld-generation")) == 0)) {
        if (select_companion() != TCL_OK) return 1;
        startup = Tcl_GetStartupScript(NULL);
    }
    if (startup == NULL && argc >= 2 &&
            _tcscmp(argv[1], _T("--docs")) == 0) {
        /* Tcl_Main needs a startup-shaped word in order to preserve the
         * remaining words as $argv until AppInit dispatches the host route.
         * The replacement is shorter than the writable CRT argument buffer. */
        _tcscpy(argv[1], _T("docs"));
        Machteld_SetHostMode(MACHTELD_HOST_DOCS);
    } else if (startup == NULL && argc >= 2 &&
            _tcscmp(argv[1], _T("--machteld-generation")) == 0) {
        _tcscpy(argv[1], _T("generation"));
        Machteld_SetHostMode(MACHTELD_HOST_GENERATION);
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
