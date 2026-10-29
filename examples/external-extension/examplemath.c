/* Copyright (c) Vincent Vercauteren. SPDX-License-Identifier: Apache-2.0 */
#include <stdint.h>
#include <tcl.h>

static int
Add(void *clientData, Tcl_Interp *interp, Tcl_Size objc, Tcl_Obj *const objv[])
{
    Tcl_WideInt a, b;
    (void)clientData;
    if (objc != 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "signed32 signed32");
        return TCL_ERROR;
    }
    if (Tcl_GetWideIntFromObj(interp, objv[1], &a) != TCL_OK ||
            Tcl_GetWideIntFromObj(interp, objv[2], &b) != TCL_OK) {
        return TCL_ERROR;
    }
    /* A deliberately small, exact API; the sum cannot overflow Tcl_WideInt. */
    if (a < INT32_MIN || a > INT32_MAX || b < INT32_MIN || b > INT32_MAX) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("operands must be signed 32-bit integers", -1));
        Tcl_SetErrorCode(interp, "EXAMPLEMATH", "ARGUMENT", "RANGE", NULL);
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, Tcl_NewWideIntObj(a + b));
    return TCL_OK;
}

DLLEXPORT int
Examplemath_Init(Tcl_Interp *interp)
{
    if (Tcl_InitStubs(interp, "9.0", 0) == NULL) {
        return TCL_ERROR;
    }
    if (Tcl_CreateNamespace(interp, "::examplemath", NULL, NULL) == NULL) {
        return TCL_ERROR;
    }
    Tcl_CreateObjCommand2(interp, "::examplemath::add", Add, NULL, NULL);
    return Tcl_PkgProvide(interp, "examplemath", "1.0");
}
