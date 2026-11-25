#include "surface_backend.h"
#include <stddef.h>
#include <string.h>

void surface_drop_shader(Surface *s) {
    DROP_COM(s->layout);
    DROP_COM(s->vs);
    DROP_COM(s->ps);
}

static HRESULT create_shader(Surface *s, ID3DBlob *v, ID3DBlob *p,
                             ID3D11VertexShader **vs, ID3D11PixelShader **ps,
                             ID3D11InputLayout **layout) {
    const D3D11_INPUT_ELEMENT_DESC elements[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, offsetof(SurfaceVertex, xyz), D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, offsetof(SurfaceVertex, rgba), D3D11_INPUT_PER_VERTEX_DATA, 0}
    };
    HRESULT hr = ID3D11Device_CreateVertexShader(s->device, ID3D10Blob_GetBufferPointer(v),
                      ID3D10Blob_GetBufferSize(v), NULL, vs);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreatePixelShader(s->device, ID3D10Blob_GetBufferPointer(p),
                                ID3D10Blob_GetBufferSize(p), NULL, ps);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateInputLayout(s->device, elements, ARRAYSIZE(elements),
                                ID3D10Blob_GetBufferPointer(v), ID3D10Blob_GetBufferSize(v), layout);
    return hr;
}

static int compile(Surface *s, Tcl_Obj *source, const char *profile, ID3DBlob **code) {
    Tcl_Size n;
    const char *text = Tcl_GetStringFromObj(source, &n);
    if (n < 1 || n > 262144) return surface_error(s->interp, "limit", "shader source must contain 1 to 262144 bytes");
    ID3DBlob *errors = NULL;
    HRESULT hr = D3DCompile(text, (size_t)n, "surface", NULL, NULL, "main", profile,
                            D3DCOMPILE_ENABLE_STRICTNESS, 0, code, &errors);
    if (FAILED(hr)) {
        surface_error(s->interp, "shader", "shader compilation failed");
        if (errors) {
            const char *detail = ID3D10Blob_GetBufferPointer(errors);
            Tcl_SetObjResult(s->interp, Tcl_ObjPrintf("%s: %s", profile, detail));
        }
    }
    DROP_COM(errors);
    return FAILED(hr) ? TCL_ERROR : TCL_OK;
}

int surface_program(Surface *s, Tcl_Obj *vertex, Tcl_Obj *pixel) {
    ID3DBlob *v = NULL, *p = NULL;
    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader *ps = NULL;
    ID3D11InputLayout *layout = NULL;
    int result = compile(s, vertex, "vs_4_0", &v);
    if (result == TCL_OK) result = compile(s, pixel, "ps_4_0", &p);
    if (result == TCL_OK && s->device) {
        HRESULT hr = create_shader(s, v, p, &vs, &ps, &layout);
        if (FAILED(hr)) result = surface_hr(s, "creating the shader program", hr);
    }
    if (result != TCL_OK) {
        DROP_COM(v); DROP_COM(p); DROP_COM(vs); DROP_COM(ps); DROP_COM(layout);
        return TCL_ERROR;
    }
    surface_drop_shader(s);
    DROP_COM(s->vsCode); DROP_COM(s->psCode);
    s->vsCode = v; s->psCode = p; s->vs = vs; s->ps = ps; s->layout = layout;
    return TCL_OK;
}

HRESULT surface_render_3d(Surface *s) {
    ID3D11DeviceContext *ctx = s->context;
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &s->rtv, NULL);
    const float clear[] = {s->clear.r, s->clear.g, s->clear.b, s->clear.a};
    ID3D11DeviceContext_ClearRenderTargetView(ctx, s->rtv, clear);
    if (!s->vertexCount) return S_OK;
    if (!s->vs) {
        HRESULT hr = create_shader(s, s->vsCode, s->psCode, &s->vs, &s->ps, &s->layout);
        if (FAILED(hr)) { surface_drop_shader(s); return hr; }
    }
    size_t bytes = sizeof(*s->vertices) * s->vertexCount;
    if (s->vbBytes < bytes) {
        DROP_COM(s->vb);
        s->vbBytes = 0;
        D3D11_BUFFER_DESC desc = {0};
        desc.ByteWidth = (UINT)bytes;
        desc.Usage = D3D11_USAGE_DYNAMIC;
        desc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        HRESULT hr = ID3D11Device_CreateBuffer(s->device, &desc, NULL, &s->vb);
        if (FAILED(hr)) return hr;
        s->vbBytes = bytes;
    }
    D3D11_MAPPED_SUBRESOURCE mapped;
    HRESULT hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)s->vb, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
    if (FAILED(hr)) return hr;
    memcpy(mapped.pData, s->vertices, bytes);
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)s->vb, 0);
    D3D11_VIEWPORT viewport = {0, 0, (float)s->width, (float)s->height, 0, 1};
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &viewport);
    ID3D11DeviceContext_RSSetState(ctx, s->raster);
    ID3D11DeviceContext_IASetInputLayout(ctx, s->layout);
    const UINT stride = sizeof(*s->vertices), offset = 0;
    ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, &s->vb, &stride, &offset);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, s->vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, s->ps, NULL, 0);
    ID3D11DeviceContext_Draw(ctx, s->vertexCount, 0);
    return S_OK;
}
