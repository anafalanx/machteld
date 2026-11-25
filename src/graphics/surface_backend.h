#ifndef MACHTELD_SURFACE_BACKEND_H
#define MACHTELD_SURFACE_BACKEND_H
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <d2d1.h>
#include <dxgi.h>
#include <dxgi1_2.h>
#include <tcl.h>
#include <tk.h>
#include <stdbool.h>
#include <stdint.h>

#define DROP_COM(p) do { if ((p) != NULL) { IUnknown_Release((IUnknown *)(p)); (p) = NULL; } } while (0)
typedef struct { float xyz[3], rgba[4]; } SurfaceVertex;
typedef struct {
    UINT w, h;
    BYTE *bgra;
    ID2D1Bitmap *gpu;
} SurfaceImage;
typedef enum { OP_RECT, OP_ELLIPSE, OP_LINE, OP_SPRITE } OpCode;
typedef struct {
    OpCode op;
    float a, b, c, d, width;
    D2D1_COLOR_F color;
    SurfaceImage *image;
} SurfaceOp;
typedef struct {
    Tcl_Interp *interp;
    Tk_Window window;
    Tcl_Command command;
    HWND hwnd;
    bool d3d, idle, invalidated, software;
    int driver, requestedW, requestedH, width, height;
    double scale;
    unsigned dpi, generation;
    D3D_DRIVER_TYPE actual;
    D3D_FEATURE_LEVEL level;
    char adapter[512];
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IDXGISwapChain *swap;
    ID3D11RenderTargetView *rtv;
    ID3D11Texture2D *readback;
    ID3DBlob *vsCode, *psCode;
    ID3D11VertexShader *vs;
    ID3D11PixelShader *ps;
    ID3D11InputLayout *layout;
    ID3D11RasterizerState *raster;
    ID3D11Buffer *vb;
    size_t vbBytes;
    ID2D1Factory *factory;
    ID2D1RenderTarget *target;
    ID2D1SolidColorBrush *brush;
    D2D1_COLOR_F clear;
    SurfaceVertex *vertices;
    UINT vertexCount;
    SurfaceOp *ops;
    Tcl_Size opCount;
    Tcl_HashTable images;
    size_t imageBytes;
} Surface;

int surface_error(Tcl_Interp *, const char *, const char *);
int surface_hr(Surface *, const char *, HRESULT);
void surface_drop_device(Surface *);
int surface_draw(Surface *, Tcl_Obj *points);
int surface_program(Surface *, Tcl_Obj *vs, Tcl_Obj *ps);
int surface_set_scene(Surface *, int objc, Tcl_Obj *const objv[]);
int surface_set_image(Surface *, Tcl_Obj *name, Tcl_Obj *w, Tcl_Obj *h, Tcl_Obj *pixels);
HRESULT surface_render_2d(Surface *);
HRESULT surface_render_3d(Surface *);
void surface_drop_shader(Surface *);
#endif
