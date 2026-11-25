/* Compile the production catalog reader against a private caller-selected
 * menu directory. Only this test DLL exposes that choice. */
#include "../../src/desktop_apps.c"

static void retire(void *data) {
    desktop_catalog **catalog = data;
    desktop_catalog_free(*catalog);
    Tcl_Free(catalog);
}

static int probe(void *data, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    desktop_catalog **catalog = data;
    const char *op = objc > 1 ? Tcl_GetString(objv[1]) : "";
    if (objc == 3 && !strcmp(op, "scan")) {
        Tcl_Obj *path = Tcl_FSGetNormalizedPath(ip, objv[2]);
        const wchar_t *dir = path ? Tcl_FSGetNativePath(path) : NULL;
        if (!dir) return TCL_ERROR;
        HRESULT apartment = com_start();
        if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE) return TCL_ERROR;
        int rc = collect(ip, "test-menu", catalog, &dir, 1, 0);
        if (SUCCEEDED(apartment)) CoUninitialize();
        return rc;
    }
    if (objc == 3 && !strcmp(op, "launch")) return desktop_launch_app(ip, *catalog, objv[2]);
    if (objc == 5 && !strcmp(op, "icon")) return desktop_app_icon(ip, *catalog, objv[2], objv[3], objv[4]);
    return failure(ip, "usage", "expected scan, launch or icon");
}

__declspec(dllexport) int Desktopcatalog_Init(Tcl_Interp *ip) {
    if (!Tcl_InitStubs(ip, "9.0", 0) || !Tk_InitStubs(ip, "9.0", 0)) return TCL_ERROR;
    desktop_catalog **catalog = Tcl_Alloc(sizeof(*catalog));
    *catalog = NULL;
    if (!Tcl_CreateObjCommand(ip, "::fixtureCatalog", probe, catalog, retire)) {
        retire(catalog);
        return TCL_ERROR;
    }
    return TCL_OK;
}
