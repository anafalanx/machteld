#include "surface_backend.h"
#include <math.h>
#include <string.h>

static int color(Tcl_Obj *obj, D2D1_COLOR_F *out) {
    Tcl_Size n;
    const char *s = Tcl_GetStringFromObj(obj, &n);
    if ((n != 7 && n != 9) || s[0] != '#') return 0;
    unsigned values[] = {0, 0, 0, 255};
    for (int j = 0; j < (n - 1) / 2; j++) {
        unsigned v = 0;
        for (int i = 0; i < 2; i++) {
            char c = s[1 + 2 * j + i];
            if (c >= '0' && c <= '9') v = 16 * v + (unsigned)(c - '0');
            else if (c >= 'a' && c <= 'f') v = 16 * v + (unsigned)(c - 'a') + 10;
            else if (c >= 'A' && c <= 'F') v = 16 * v + (unsigned)(c - 'A') + 10;
            else return 0;
        }
        values[j] = v;
    }
    *out = (D2D1_COLOR_F){values[0]/255.f, values[1]/255.f, values[2]/255.f, values[3]/255.f};
    return 1;
}

static int coord(Tcl_Obj *o, float *f) {
    double d;
    if (Tcl_GetDoubleFromObj(NULL, o, &d) != TCL_OK || !isfinite(d) || fabs(d) > 1000000) return 0;
    *f = (float)d;
    return 1;
}

static int parse_primitive(Surface *s, Tcl_Obj *obj, SurfaceOp *op) {
    Tcl_Obj **v; Tcl_Size n;
    if (Tcl_ListObjGetElements(NULL, obj, &n, &v) != TCL_OK || (n != 6 && n != 7)) return 0;
    static const char *const names[] = {"rect", "ellipse", "line", "sprite", NULL};
    int k;
    if (Tcl_GetIndexFromObj(NULL, v[0], names, "primitive", TCL_EXACT, &k) != TCL_OK) return 0;
    op->op = (OpCode)k;
    if (n != (k == OP_LINE ? 7 : 6)) return 0;
    int off = k == OP_SPRITE ? 2 : 1;
    if (!coord(v[off], &op->a) || !coord(v[off+1], &op->b) ||
        !coord(v[off+2], &op->c) || !coord(v[off+3], &op->d)) return 0;
    if (k != OP_LINE && (op->c < 0 || op->d < 0)) return 0;
    if (k == OP_SPRITE) {
        Tcl_HashEntry *e = Tcl_FindHashEntry(&s->images, Tcl_GetString(v[1]));
        if (!e) return 0;
        op->image = Tcl_GetHashValue(e);
    } else {
        if (!color(v[n-1], &op->color)) return 0;
        if (k == OP_LINE && (!coord(v[5], &op->width) || op->width <= 0)) return 0;
    }
    return 1;
}

int surface_set_scene(Surface *s, int objc, Tcl_Obj *const objv[]) {
    if (objc != 4) { Tcl_WrongNumArgs(s->interp, 2, objv, "clearColor geometry"); return TCL_ERROR; }
    D2D1_COLOR_F clear;
    if (!color(objv[2], &clear)) return surface_error(s->interp, "format", "color must be #rrggbb or #rrggbbaa");
    Tcl_Obj **items; Tcl_Size n;
    if (Tcl_ListObjGetElements(s->interp, objv[3], &n, &items) != TCL_OK) return TCL_ERROR;
    if (n > 196608) return surface_error(s->interp, "limit", "too many vertices or drawing operations");
    if (s->d3d) {
        if (n % 3) return surface_error(s->interp, "format", "a triangle list must have a multiple of three vertices");
        if (n && !s->vsCode) return surface_error(s->interp, "shader", "install a shader before drawing triangles");
        SurfaceVertex *vertices = (SurfaceVertex *)Tcl_Alloc((size_t)n * sizeof(*vertices));
        for (Tcl_Size i = 0; i < n; i++) {
            Tcl_Obj **v; Tcl_Size count;
            D2D1_COLOR_F c;
            if (Tcl_ListObjGetElements(NULL, items[i], &count, &v) != TCL_OK || count != 4 ||
                !coord(v[0], &vertices[i].xyz[0]) || !coord(v[1], &vertices[i].xyz[1]) ||
                !coord(v[2], &vertices[i].xyz[2]) || !color(v[3], &c)) {
                Tcl_Free(vertices);
                return surface_error(s->interp, "format", "each vertex requires finite x y z and a color");
            }
            vertices[i].rgba[0] = c.r; vertices[i].rgba[1] = c.g;
            vertices[i].rgba[2] = c.b; vertices[i].rgba[3] = c.a;
        }
        if (s->vertices) Tcl_Free(s->vertices);
        s->vertices = vertices; s->vertexCount = (UINT)n;
    } else {
        SurfaceOp *ops = (SurfaceOp *)Tcl_Alloc((size_t)n * sizeof(*ops));
        for (Tcl_Size i = 0; i < n; i++) {
            if (!parse_primitive(s, items[i], &ops[i])) {
                Tcl_Free(ops);
                return surface_error(s->interp, "format", "invalid rectangle, ellipse, line or named sprite");
            }
        }
        if (s->ops) Tcl_Free(s->ops);
        s->ops = ops; s->opCount = n;
    }
    s->clear = clear;
    return TCL_OK;
}

int surface_set_image(Surface *s, Tcl_Obj *name, Tcl_Obj *w, Tcl_Obj *h, Tcl_Obj *pixels) {
    int width, height;
    if (Tcl_GetIntFromObj(NULL, w, &width) != TCL_OK || Tcl_GetIntFromObj(NULL, h, &height) != TCL_OK ||
        width < 1 || height < 1 || width > 4096 || height > 4096)
        return surface_error(s->interp, "size", "image dimensions must be between 1 and 4096");
    Tcl_Size length, nameLength;
    const BYTE *rgba = Tcl_GetByteArrayFromObj(pixels, &length);
    const char *key = Tcl_GetStringFromObj(name, &nameLength);
    if (!nameLength || nameLength > 256 || memchr(key, 0, (size_t)nameLength))
        return surface_error(s->interp, "format", "invalid sprite name");
    size_t bytes = (size_t)width * height * 4;
    if ((size_t)length != bytes) return surface_error(s->interp, "format", "supply four RGBA bytes per pixel");
    Tcl_HashEntry *e = Tcl_FindHashEntry(&s->images, key);
    SurfaceImage *im = e ? Tcl_GetHashValue(e) : NULL;
    size_t old = im ? (size_t)im->w * im->h * 4 : 0;
    if (s->imageBytes - old + bytes > 67108864 || (!im && s->images.numEntries >= 4096))
        return surface_error(s->interp, "limit", "surface sprite storage is full");
    if (!im) {
        int fresh;
        e = Tcl_CreateHashEntry(&s->images, key, &fresh);
        im = (SurfaceImage *)Tcl_Alloc(sizeof(*im));
        *im = (SurfaceImage){0};
        Tcl_SetHashValue(e, im);
    }
    DROP_COM(im->gpu);
    if (im->bgra) Tcl_Free(im->bgra);
    im->w = (UINT)width; im->h = (UINT)height;
    im->bgra = (BYTE *)Tcl_Alloc(bytes);
    for (size_t i = 0; i < bytes; i += 4) {
        unsigned alpha = rgba[i+3];
        im->bgra[i] = (BYTE)((rgba[i+2] * alpha + 127) / 255);
        im->bgra[i+1] = (BYTE)((rgba[i+1] * alpha + 127) / 255);
        im->bgra[i+2] = (BYTE)((rgba[i] * alpha + 127) / 255);
        im->bgra[i+3] = (BYTE)alpha;
    }
    s->imageBytes = s->imageBytes - old + bytes;
    return TCL_OK;
}

HRESULT surface_render_2d(Surface *s) {
    ID2D1RenderTarget *target = s->target;
    float dpi = (float)(s->dpi * s->scale);
    ID2D1RenderTarget_SetDpi(target, dpi, dpi);
    ID2D1RenderTarget_BeginDraw(target);
    ID2D1RenderTarget_Clear(target, &s->clear);
    HRESULT hr = S_OK;
    for (Tcl_Size i = 0; i < s->opCount && SUCCEEDED(hr); i++) {
        SurfaceOp *op = &s->ops[i];
        D2D1_RECT_F rect = {op->a, op->b, op->a + op->c, op->b + op->d};
        ID2D1Brush *brush = (ID2D1Brush *)s->brush;
        if (op->op != OP_SPRITE) ID2D1SolidColorBrush_SetColor(s->brush, &op->color);
        switch (op->op) {
        case OP_RECT:
            ID2D1RenderTarget_FillRectangle(target, &rect, brush);
            break;
        case OP_ELLIPSE: {
            D2D1_ELLIPSE ellipse = {{op->a, op->b}, op->c, op->d};
            ID2D1RenderTarget_FillEllipse(target, &ellipse, brush);
            break;
        }
        case OP_LINE: {
            D2D1_POINT_2F a = {op->a, op->b}, b = {op->c, op->d};
            ID2D1RenderTarget_DrawLine(target, a, b, brush, op->width, NULL);
            break;
        }
        case OP_SPRITE: {
            SurfaceImage *im = op->image;
            if (!im->gpu) {
                D2D1_SIZE_U size = {im->w, im->h};
                D2D1_BITMAP_PROPERTIES p = {{DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED}, 96, 96};
                hr = ID2D1RenderTarget_CreateBitmap(target, size, im->bgra, 4 * im->w, &p, &im->gpu);
            }
            if (SUCCEEDED(hr))
                ID2D1RenderTarget_DrawBitmap(target, im->gpu, &rect, 1, D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR, NULL);
            break;
        }
        }
    }
    HRESULT end = ID2D1RenderTarget_EndDraw(target, NULL, NULL);
    return FAILED(end) ? end : hr;
}
