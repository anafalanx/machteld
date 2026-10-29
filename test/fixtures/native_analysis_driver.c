/* Headless interpreter for instrumenting Machteld's JSON implementation and
 * yyjson without rebuilding the installed Tcl/Tk dependencies or full host. */
#undef USE_TCL_STUBS
#include "../../src/machteld.h"
#include "../../src/wintext.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

extern int Machteldjson_Init(Tcl_Interp *interp);

int wmain(int argc, wchar_t **argv) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    if (argc < 2) return 2;
    char *executable = mt_wide_to_utf8(argv[0], -1);
    if (executable == NULL) return 2;
    Tcl_FindExecutable(executable);
    free(executable);
    Tcl_Interp *interp = Tcl_CreateInterp();
    Tcl_Obj *arguments = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(arguments);
    for (int i = 2; i < argc; i++) {
        Tcl_DString text;
        Tcl_DStringInit(&text);
        Tcl_WCharToUtfDString(argv[i], -1, &text);
        Tcl_ListObjAppendElement(interp, arguments,
            Tcl_NewStringObj(Tcl_DStringValue(&text), Tcl_DStringLength(&text)));
        Tcl_DStringFree(&text);
    }
    Tcl_SetVar2Ex(interp, "argv", NULL, arguments, TCL_GLOBAL_ONLY);
    Tcl_SetVar2Ex(interp, "argc", NULL, Tcl_NewIntObj(argc - 2), TCL_GLOBAL_ONLY);
    Tcl_DecrRefCount(arguments);
    Tcl_DString script;
    Tcl_DStringInit(&script);
    Tcl_WCharToUtfDString(argv[1], -1, &script);
    int result = Tcl_Eval(interp, "namespace eval ::machteld {}");
    if (result == TCL_OK) result = Machteldjson_Init(interp);
    if (result == TCL_OK) result = Tcl_CreateAlias(interp, "json", interp,
        "::machteld::json", 0, NULL);
    if (result == TCL_OK) result = Tcl_PkgProvide(interp, "machteld", MACHTELD_VERSION);
    if (result == TCL_OK) result = Tcl_EvalFile(interp, Tcl_DStringValue(&script));
    Tcl_DStringFree(&script);
    if (result != TCL_OK) {
        const char *error = Tcl_GetVar(interp, "errorInfo", TCL_GLOBAL_ONLY);
        fprintf(stderr, "%s\n", error == NULL ? Tcl_GetStringResult(interp) : error);
    }
    Tcl_DeleteInterp(interp);
    Tcl_Finalize();
    return result == TCL_OK ? 0 : 1;
}
