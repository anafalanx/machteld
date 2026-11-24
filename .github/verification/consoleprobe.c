#include <windows.h>
#include <tcl.h>
__declspec(dllexport) int Consoleprobe_Init(Tcl_Interp *interp)
{
    if (!Tcl_InitStubs(interp, "9.0", 0)) return TCL_ERROR;
    BOOL in_job = FALSE;
    if (!IsProcessInJob(GetCurrentProcess(), NULL, &in_job)) return TCL_ERROR;
    Tcl_Obj *facts = Tcl_ObjPrintf("codepage %u window %d job %d", (unsigned)GetConsoleCP(), GetConsoleWindow() != NULL, !!in_job);
    return Tcl_SetVar2Ex(interp, "::consoleprobe", NULL, facts, TCL_GLOBAL_ONLY) ? TCL_OK : TCL_ERROR;
}
