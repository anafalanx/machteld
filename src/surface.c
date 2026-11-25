/* Generic Tk child windows. Tcl owns the geometry, colors, images, shader
 * programs, input bindings and animation clock. */
#include "graphics/surface_backend.h"
#include <tkPlatDecls.h>
#include <math.h>
#include <string.h>

int surface_error(Tcl_Interp *interp, const char *code, const char *message) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(message, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "SURFACE", code, NULL);
    return TCL_ERROR;
}

int surface_hr(Surface *s, const char *operation, HRESULT hr) {
    surface_error(s->interp, "device", "");
    Tcl_SetObjResult(s->interp, Tcl_ObjPrintf("%s failed (HRESULT 0x%08lx)", operation, (unsigned long)hr));
    return TCL_ERROR;
}

static void redraw(void *data) {
    Surface *s = data;
    s->idle = false;
    if (!s->window || !Tk_IsMapped(s->window)) return;
    Tcl_Interp *interp = s->interp;
    Tcl_InterpState state = Tcl_SaveInterpState(interp, TCL_OK);
    if (surface_draw(s, NULL) != TCL_OK) Tcl_BackgroundException(interp, TCL_ERROR);
    Tcl_RestoreInterpState(interp, state);
}

static void queue_redraw(Surface *s) {
    if (!s->idle) { s->idle = true; Tcl_DoWhenIdle(redraw, s); }
}

static void events(void *data, XEvent *ev) {
    Surface *s = data;
    if (ev->type == DestroyNotify) {
        s->window = NULL;
        Tcl_DeleteCommandFromToken(s->interp, s->command);
    } else if (ev->type == Expose || ev->type == ConfigureNotify || ev->type == MapNotify) {
        queue_redraw(s);
    }
}

static void destroy_surface(void *data) {
    Surface *s = data;
    if (s->idle) Tcl_CancelIdleCall(redraw, s);
    surface_drop_device(s);
    DROP_COM(s->vsCode); DROP_COM(s->psCode);
    Tcl_HashSearch search;
    for (Tcl_HashEntry *e = Tcl_FirstHashEntry(&s->images, &search); e; e = Tcl_NextHashEntry(&search)) {
        SurfaceImage *im = Tcl_GetHashValue(e);
        Tcl_Free(im->bgra);
        Tcl_Free(im);
    }
    Tcl_DeleteHashTable(&s->images);
    if (s->ops) Tcl_Free(s->ops);
    if (s->vertices) Tcl_Free(s->vertices);
    if (s->window) {
        Tk_DeleteEventHandler(s->window, ExposureMask | StructureNotifyMask, events, s);
        Tk_DestroyWindow(s->window);
    }
    Tcl_Free(s);
}

static int configure(Surface *s, int n, Tcl_Obj *const opts[], bool creating) {
    int w = s->requestedW, h = s->requestedH, driver = s->driver;
    double scale = s->scale;
    if (n % 2) return surface_error(s->interp, "format", "each surface option requires a value");
    static const char *const keys[] = {"-width", "-height", "-scale", "-driver", NULL};
    static const char *const drivers[] = {"auto", "hardware", "warp", NULL};
    for (int i = 0; i < n; i += 2) {
        int key;
        if (Tcl_GetIndexFromObj(s->interp, opts[i], keys, "option", TCL_EXACT, &key) != TCL_OK) return TCL_ERROR;
        if (key <= 1) {
            int value;
            if (Tcl_GetIntFromObj(NULL, opts[i+1], &value) != TCL_OK || value <= 0 || value > 8192)
                return surface_error(s->interp, "size", "surface width and height must be between 1 and 8192");
            if (key == 0) w = value; else h = value;
        } else if (key == 2) {
            if (Tcl_GetDoubleFromObj(NULL, opts[i+1], &scale) != TCL_OK || !isfinite(scale) || scale < 0.125 || scale > 8)
                return surface_error(s->interp, "size", "drawing scale must be between 0.125 and 8");
            if (s->d3d) return surface_error(s->interp, "format", "-scale applies to Direct2D logical coordinates");
        } else {
            if (!creating) return surface_error(s->interp, "format", "choose the driver when creating a surface");
            if (Tcl_GetIndexFromObj(s->interp, opts[i+1], drivers, "driver", TCL_EXACT, &driver) != TCL_OK) return TCL_ERROR;
        }
    }
    if ((size_t)w * h > 16777216) return surface_error(s->interp, "size", "surface exceeds 16777216 pixels");
    s->requestedW = w; s->requestedH = h; s->scale = scale; s->driver = driver;
    if (s->window) { Tk_GeometryRequest(s->window, w, h); queue_redraw(s); }
    return TCL_OK;
}

static void put(Tcl_Obj *dict, const char *key, Tcl_Obj *value) {
    Tcl_DictObjPut(NULL, dict, Tcl_NewStringObj(key,-1), value);
}

static int widget(void *data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Surface *s = data;
    static const char *const names[] = {"draw","pixels","info","configure","shader","image","recreate",NULL};
    int mode;
    if (objc < 2) { Tcl_WrongNumArgs(interp, 1, objv, "operation ?arg ...?"); return TCL_ERROR; }
    if (Tcl_GetIndexFromObj(interp, objv[1], names, "operation", TCL_EXACT, &mode) != TCL_OK) return TCL_ERROR;
    switch (mode) {
    case 0:
        if (surface_set_scene(s, objc, objv) != TCL_OK) return TCL_ERROR;
        if (s->idle) { Tcl_CancelIdleCall(redraw, s); s->idle = false; }
        return surface_draw(s, NULL);
    case 1:
        if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "pixelPoints"); return TCL_ERROR; }
        return surface_draw(s, objv[2]);
    case 2: {
        if (objc != 2) goto noargs;
        Tcl_Obj *dict = Tcl_NewDictObj();
        const char *driver = !s->device ? "pending" : s->actual == D3D_DRIVER_TYPE_HARDWARE ? "hardware" : "warp";
        put(dict, "backend", Tcl_NewStringObj(s->d3d ? "d3d" : "d2d", -1));
        put(dict, "driver", Tcl_NewStringObj(driver, -1));
        put(dict, "adapter", Tcl_NewStringObj(s->adapter, -1));
        put(dict, "software", Tcl_NewBooleanObj(s->software));
        put(dict, "featureLevel", Tcl_ObjPrintf("%x", (unsigned)s->level));
        put(dict, "width", Tcl_NewIntObj(s->width)); put(dict, "height", Tcl_NewIntObj(s->height));
        put(dict, "dpi", Tcl_NewIntObj((int)s->dpi));
        put(dict, "scale", Tcl_NewDoubleObj(s->scale));
        put(dict, "generation", Tcl_NewWideIntObj(s->generation));
        Tcl_SetObjResult(interp, dict);
        return TCL_OK;
    }
    case 3:
        return configure(s, objc-2, objv+2, false);
    case 4:
        if (!s->d3d) return surface_error(interp, "format", "shader requires a Direct3D surface");
        if (objc != 4) { Tcl_WrongNumArgs(interp, 2, objv, "vertexHlsl pixelHlsl"); return TCL_ERROR; }
        if (surface_program(s, objv[2], objv[3]) != TCL_OK) return TCL_ERROR;
        queue_redraw(s);
        return TCL_OK;
    case 5:
        if (s->d3d) return surface_error(interp, "format", "image requires a Direct2D surface");
        if (objc != 6) { Tcl_WrongNumArgs(interp, 2, objv, "name width height rgbaBytes"); return TCL_ERROR; }
        if (surface_set_image(s, objv[2], objv[3], objv[4], objv[5]) != TCL_OK) return TCL_ERROR;
        queue_redraw(s);
        return TCL_OK;
    default:
        if (objc != 2) goto noargs;
        s->invalidated = true;
        return surface_draw(s, NULL);
    }
noargs:
    Tcl_WrongNumArgs(interp, 2, objv, NULL);
    return TCL_ERROR;
}

static int create_surface(void *unused, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)unused;
    if (objc < 3) { Tcl_WrongNumArgs(interp, 1, objv, "d2d|d3d path ?option value ...?"); return TCL_ERROR; }
    static const char *const modes[] = {"d2d", "d3d", NULL};
    int mode;
    if (Tcl_GetIndexFromObj(interp, objv[1], modes, "backend", TCL_EXACT, &mode) != TCL_OK) return TCL_ERROR;
    if (!Tcl_PkgRequire(interp, "Tk", "9.0", 0)) return TCL_ERROR;
    const char *path = Tcl_GetString(objv[2]);
    if (*path != '.' || Tcl_FindCommand(interp, path, NULL, TCL_GLOBAL_ONLY))
        return surface_error(interp, "format", "supply an available Tk child window path");
    Surface *s = (Surface *)Tcl_Alloc(sizeof(*s));
    *s = (Surface){.interp=interp, .d3d=(mode == 1), .requestedW=320, .requestedH=240,
                   .scale=1, .dpi=96, .clear={0,0,0,1}};
    Tcl_InitHashTable(&s->images, TCL_STRING_KEYS);
    if (configure(s, objc-3, objv+3, true) != TCL_OK) { destroy_surface(s); return TCL_ERROR; }
    s->window = Tk_CreateWindowFromPath(interp, Tk_MainWindow(interp), path, NULL);
    if (!s->window) { destroy_surface(s); return TCL_ERROR; }
    Tk_SetClass(s->window, s->d3d ? "MachteldDirect3D" : "MachteldDirect2D");
    Tk_GeometryRequest(s->window, s->requestedW, s->requestedH);
    Tk_MakeWindowExist(s->window);
    s->hwnd = Tk_GetHWND(Tk_WindowId(s->window));
    if (!s->hwnd) { destroy_surface(s); return surface_error(interp, "device", "Tk has no native child window"); }
    s->command = Tcl_CreateObjCommand(interp, path, widget, s, destroy_surface);
    Tk_CreateEventHandler(s->window, ExposureMask | StructureNotifyMask, events, s);
    Tcl_SetObjResult(interp, objv[2]);
    return TCL_OK;
}

int Machteldsurface_Init(Tcl_Interp *interp) {
    Tcl_CreateObjCommand(interp, "::machteld::surface", create_surface, NULL, NULL);
    return TCL_OK;
}
