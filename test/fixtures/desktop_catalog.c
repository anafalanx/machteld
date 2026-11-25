/* Compile the production catalog reader against a private caller-selected
 * menu directory. Only this test DLL exposes that choice. */
#include "../../src/desktop_apps.c"
#include "tkPlatDecls.h"

/* Build the same Unicode HDROP the Shell transfers. Send only to a widget
 * of this interpreter with an active file-drop registration. */
static int send_drop(Tcl_Interp *ip, Tcl_Obj *widget, Tcl_Obj *files) {
    Tk_Window main = Tk_MainWindow(ip);
    Tk_Window w = main ? Tk_NameToWindow(ip, Tcl_GetString(widget), main) : NULL;
    HWND window = w && Tk_WindowId(w) ? Tk_GetHWND(Tk_WindowId(w)) : NULL;
    if (!window || !(GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_ACCEPTFILES))
        return failure(ip, "badvalue", "fixture requires a registered local widget");
    Tcl_Obj **elements;
    Tcl_Size count;
    if (Tcl_ListObjGetElements(ip, files, &count, &elements) != TCL_OK) return TCL_ERROR;
    Tcl_DString bytes;
    Tcl_DStringInit(&bytes);
    for (Tcl_Size i = 0; i < count; ++i) {
        WCHAR *wide = mt_utf8_to_wide(Tcl_GetString(elements[i]));
        if (!wide) {
            Tcl_DStringFree(&bytes);
            return failure(ip, "badvalue", "invalid fixture path");
        }
        Tcl_DStringAppend(&bytes, (const char *)wide, (Tcl_Size)((wcslen(wide) + 1) * sizeof(*wide)));
        free(wide);
    }
    size_t n = (size_t)Tcl_DStringLength(&bytes);
    HGLOBAL handle = GlobalAlloc(GHND, sizeof(DROPFILES) + n + 2 * sizeof(WCHAR));
    DROPFILES *drop = handle ? GlobalLock(handle) : NULL;
    if (!drop) {
        if (handle) GlobalFree(handle);
        Tcl_DStringFree(&bytes);
        return failure(ip, "oserror", "could not allocate fixture drop");
    }
    drop->pFiles = sizeof(*drop);
    drop->fWide = TRUE;
    memcpy(drop + 1, Tcl_DStringValue(&bytes), n);
    Tcl_DStringFree(&bytes);
    GlobalUnlock(handle);
    SendMessageW(window, WM_DROPFILES, (WPARAM)handle, 0);
    return TCL_OK;
}

static void retire(void *data) {
    desktop_catalog **catalog = data;
    desktop_catalog_free(*catalog);
    Tcl_Free(catalog);
}

static int probe(void *data, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    desktop_catalog **catalog = data;
    const char *op = objc > 1 ? Tcl_GetString(objv[1]) : "";
    if (objc == 4 && !strcmp(op, "drop")) return send_drop(ip, objv[2], objv[3]);
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
