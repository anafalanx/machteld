/* Tk child swap-chain lifecycle and pre-Present readback adapted from the MIT
 * D3D Tk spike (Vincent Vercauteren) and Lunar (the Time Actual authors). */
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include "surface_backend.h"

static void drop_targets(Surface *s) {
    if (s->context) ID3D11DeviceContext_ClearState(s->context);
    Tcl_HashSearch search;
    for (Tcl_HashEntry *e = Tcl_FirstHashEntry(&s->images, &search); e;
         e = Tcl_NextHashEntry(&search)) {
        SurfaceImage *im = Tcl_GetHashValue(e);
        DROP_COM(im->gpu);
    }
    DROP_COM(s->brush);
    DROP_COM(s->target);
    DROP_COM(s->rtv);
    DROP_COM(s->readback);
    s->width = s->height = 0;
}

void surface_drop_device(Surface *s) {
    drop_targets(s);
    surface_drop_shader(s);
    DROP_COM(s->vb);
    s->vbBytes = 0;
    DROP_COM(s->raster);
    DROP_COM(s->factory);
    DROP_COM(s->swap);
    if (s->context) ID3D11DeviceContext_Flush(s->context);
    DROP_COM(s->context);
    DROP_COM(s->device);
}

static HRESULT make_device(Surface *s, UINT w, UINT h) {
    DXGI_SWAP_CHAIN_DESC desc = {0};
    desc.BufferDesc.Width = w;
    desc.BufferDesc.Height = h;
    desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = desc.BufferCount = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.OutputWindow = s->hwnd;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                       D3D_FEATURE_LEVEL_10_0};
    const D3D_DRIVER_TYPE drivers[] = {D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP};
    HRESULT hr = E_FAIL;
    for (int i = 0; i < 2; i++) {
        if (s->driver && s->driver != i + 1) continue;
        hr = D3D11CreateDeviceAndSwapChain(NULL, drivers[i], NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            levels, ARRAYSIZE(levels), D3D11_SDK_VERSION, &desc, &s->swap, &s->device,
            &s->level, &s->context);
        if (SUCCEEDED(hr)) { s->actual = drivers[i]; break; }
    }
    if (FAILED(hr)) return hr;
    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *adapter = NULL;
    IDXGIAdapter1 *adapter1 = NULL;
    DXGI_ADAPTER_DESC1 detail = {0};
    s->adapter[0] = 0;
    s->software = s->actual == D3D_DRIVER_TYPE_WARP;
    if (SUCCEEDED(ID3D11Device_QueryInterface(s->device, &IID_IDXGIDevice, (void **)&dxgi)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &adapter)) &&
        SUCCEEDED(IDXGIAdapter_QueryInterface(adapter, &IID_IDXGIAdapter1, (void **)&adapter1)) &&
        SUCCEEDED(IDXGIAdapter1_GetDesc1(adapter1, &detail))) {
        s->software = (detail.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
        WideCharToMultiByte(CP_UTF8, 0, detail.Description, -1, s->adapter, sizeof(s->adapter), NULL, NULL);
    }
    DROP_COM(adapter1); DROP_COM(adapter); DROP_COM(dxgi);
    if (s->d3d) {
        D3D11_RASTERIZER_DESC raster = {0};
        raster.FillMode = D3D11_FILL_SOLID;
        raster.CullMode = D3D11_CULL_NONE;
        raster.DepthClipEnable = TRUE;
        hr = ID3D11Device_CreateRasterizerState(s->device, &raster, &s->raster);
    } else {
        hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &IID_ID2D1Factory,
                               NULL, (void **)&s->factory);
    }
    if (FAILED(hr)) surface_drop_device(s);
    else s->generation++;
    return hr;
}

static HRESULT size_targets(Surface *s, UINT w, UINT h) {
    HRESULT hr;
    if (!s->device) {
        hr = make_device(s, w, h);
        if (FAILED(hr)) return hr;
    } else {
        drop_targets(s);
        hr = IDXGISwapChain_ResizeBuffers(s->swap, 0, w, h, DXGI_FORMAT_UNKNOWN, 0);
        if (FAILED(hr)) return hr;
    }
    ID3D11Texture2D *buffer = NULL;
    hr = IDXGISwapChain_GetBuffer(s->swap, 0, &IID_ID3D11Texture2D, (void **)&buffer);
    if (SUCCEEDED(hr) && s->d3d)
        hr = ID3D11Device_CreateRenderTargetView(s->device, (ID3D11Resource *)buffer, NULL, &s->rtv);
    if (SUCCEEDED(hr) && !s->d3d) {
        IDXGISurface *surface = NULL;
        hr = ID3D11Texture2D_QueryInterface(buffer, &IID_IDXGISurface, (void **)&surface);
        if (SUCCEEDED(hr)) {
            D2D1_RENDER_TARGET_PROPERTIES p = {0};
            p.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
            p.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED;
            hr = ID2D1Factory_CreateDxgiSurfaceRenderTarget(s->factory, surface, &p, &s->target);
            DROP_COM(surface);
        }
        if (SUCCEEDED(hr))
            hr = ID2D1RenderTarget_CreateSolidColorBrush(s->target, &s->clear, NULL, &s->brush);
    }
    DROP_COM(buffer);
    if (FAILED(hr)) drop_targets(s);
    else { s->width = (int)w; s->height = (int)h; }
    return hr;
}

static HRESULT read_pixels(Surface *s, const POINT *points, Tcl_Size count, Tcl_Obj *colors) {
    ID3D11Texture2D *buffer = NULL;
    HRESULT hr = IDXGISwapChain_GetBuffer(s->swap, 0, &IID_ID3D11Texture2D, (void **)&buffer);
    if (FAILED(hr)) return hr;
    if (!s->readback) {
        D3D11_TEXTURE2D_DESC desc;
        ID3D11Texture2D_GetDesc(buffer, &desc);
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = desc.MiscFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        hr = ID3D11Device_CreateTexture2D(s->device, &desc, NULL, &s->readback);
    }
    if (SUCCEEDED(hr)) {
        ID3D11DeviceContext_CopyResource(s->context, (ID3D11Resource *)s->readback, (ID3D11Resource *)buffer);
        D3D11_MAPPED_SUBRESOURCE mapped;
        hr = ID3D11DeviceContext_Map(s->context, (ID3D11Resource *)s->readback, 0, D3D11_MAP_READ, 0, &mapped);
        if (SUCCEEDED(hr)) {
            for (Tcl_Size i = 0; i < count; i++) {
                const BYTE *p = (const BYTE *)mapped.pData + (size_t)points[i].y * mapped.RowPitch
                              + (size_t)points[i].x * 4;
                Tcl_ListObjAppendElement(NULL, colors, Tcl_ObjPrintf("#%02x%02x%02x%02x", p[2], p[1], p[0], p[3]));
            }
            ID3D11DeviceContext_Unmap(s->context, (ID3D11Resource *)s->readback, 0);
        }
    }
    DROP_COM(buffer);
    return hr;
}

int surface_draw(Surface *s, Tcl_Obj *sample) {
    RECT rect;
    if (!GetClientRect(s->hwnd, &rect) || rect.right < 1 || rect.bottom < 1)
        return surface_error(s->interp, "size", "the surface has no drawable client area");
    int w = (int)rect.right, h = (int)rect.bottom;
    if (w > 8192 || h > 8192 || (size_t)w * h > 16777216)
        return surface_error(s->interp, "size", "the surface exceeds its drawable pixel limit");
    POINT *points = NULL;
    Tcl_Size count = 0;
    if (sample) {
        Tcl_Obj **items;
        if (Tcl_ListObjGetElements(s->interp, sample, &count, &items) != TCL_OK) return TCL_ERROR;
        if (count > 65536) return surface_error(s->interp, "limit", "too many sample points");
        points = (POINT *)Tcl_Alloc((size_t)count * sizeof(*points));
        for (Tcl_Size i = 0; i < count; i++) {
            Tcl_Size n;
            Tcl_Obj **v;
            int x, y;
            if (Tcl_ListObjGetElements(NULL, items[i], &n, &v) != TCL_OK || n != 2 ||
                Tcl_GetIntFromObj(NULL, v[0], &x) != TCL_OK || Tcl_GetIntFromObj(NULL, v[1], &y) != TCL_OK ||
                x < 0 || x >= w || y < 0 || y >= h) {
                Tcl_Free(points);
                return surface_error(s->interp, "size", "each sample must be an integer pixel inside the surface");
            }
            points[i] = (POINT){x, y};
        }
    }
    s->dpi = GetDpiForWindow(s->hwnd);
    if (!s->dpi) s->dpi = 96;
    HRESULT hr = E_FAIL;
    for (int attempt = 0; attempt < 2; attempt++) {
        Tcl_Obj *colors = Tcl_NewListObj(0, NULL);
        Tcl_IncrRefCount(colors);
        if (s->invalidated) {
            s->invalidated = false;
            hr = DXGI_ERROR_DEVICE_RESET;
        } else {
            hr = (w != s->width || h != s->height) ? size_targets(s, (UINT)w, (UINT)h) : S_OK;
        }
        if (SUCCEEDED(hr)) hr = s->d3d ? surface_render_3d(s) : surface_render_2d(s);
        if (SUCCEEDED(hr) && count) hr = read_pixels(s, points, count, colors);
        if (SUCCEEDED(hr)) hr = IDXGISwapChain_Present(s->swap, 0, 0);
        if (SUCCEEDED(hr) && sample) Tcl_SetObjResult(s->interp, colors);
        Tcl_DecrRefCount(colors);
        if (hr != DXGI_ERROR_DEVICE_REMOVED && hr != DXGI_ERROR_DEVICE_RESET && hr != D2DERR_RECREATE_TARGET) break;
        surface_drop_device(s);
    }
    if (points) Tcl_Free(points);
    return FAILED(hr) ? surface_hr(s, "drawing the surface", hr) : TCL_OK;
}
