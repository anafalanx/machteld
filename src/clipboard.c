#include <windows.h>
#include "tcl.h"

static int
ClipboardCmd(void *clientData, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    static const char *const operations[] = {"owned", NULL};
    int operation;
    (void)clientData;
    if (objc != 2 || Tcl_GetIndexFromObj(NULL, objv[1], operations,
            "operation", TCL_EXACT, &operation) != TCL_OK) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("usage: ::machteld::clipboard owned", -1));
        Tcl_SetErrorCode(interp, "MACHTELD", "CLIPBOARD", "usage", NULL);
        return TCL_ERROR;
    }

    HWND owner = GetClipboardOwner();
    DWORD pid = 0;
    int owned = owner != NULL && GetWindowThreadProcessId(owner, &pid) != 0
            && pid == GetCurrentProcessId();
    Tcl_SetObjResult(interp, Tcl_NewBooleanObj(owned));
    return TCL_OK;
}

int
Machteldclipboard_Init(Tcl_Interp *interp)
{
    if (Tcl_FindNamespace(interp, "::machteld", NULL, TCL_GLOBAL_ONLY) == NULL &&
            Tcl_CreateNamespace(interp, "::machteld", NULL, NULL) == NULL) {
        return TCL_ERROR;
    }
    return Tcl_CreateObjCommand(interp, "::machteld::clipboard", ClipboardCmd,
            NULL, NULL) == NULL ? TCL_ERROR : TCL_OK;
}
