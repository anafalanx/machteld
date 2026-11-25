#include "foundation.h"
#include <string.h>

typedef struct {
    HRESULT (WINAPI *startup)(ULONG, DWORD);
    HRESULT (WINAPI *shutdown)(void);
    HRESULT (WINAPI *sample)(IMFSample **);
    HRESULT (WINAPI *type)(IMFMediaType **);
    HRESULT (WINAPI *buffer)(DWORD, IMFMediaBuffer **);
    HRESULT (WINAPI *aligned)(DWORD, DWORD, IMFMediaBuffer **);
} MediaFoundation;

static MediaFoundation mf;
static INIT_ONCE once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK resolve(PINIT_ONCE unused, void *parameter, void **context) {
    (void)unused; (void)parameter; (void)context;
    HMODULE module = LoadLibraryExW(L"mfplat.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return TRUE;
    MediaFoundation api = {0};
#define RESOLVE(member, name) do { \
    FARPROC address = GetProcAddress(module, name); \
    if (!address) { FreeLibrary(module); return TRUE; } \
    memcpy(&api.member, &address, sizeof address); \
} while (0)
    RESOLVE(startup, "MFStartup");
    RESOLVE(shutdown, "MFShutdown");
    RESOLVE(sample, "MFCreateSample");
    RESOLVE(type, "MFCreateMediaType");
    RESOLVE(buffer, "MFCreateMemoryBuffer");
    RESOLVE(aligned, "MFCreateAlignedMemoryBuffer");
#undef RESOLVE
    mf = api;
    return TRUE;
}

HRESULT media_foundation_start(void) {
    InitOnceExecuteOnce(&once, resolve, NULL, NULL);
    return mf.startup ? mf.startup(MF_VERSION, MFSTARTUP_LITE) : HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);
}
void media_foundation_stop(void) { mf.shutdown(); }
HRESULT media_sample(IMFSample **sample) { return mf.sample(sample); }
HRESULT media_type(IMFMediaType **type) { return mf.type(type); }
HRESULT media_buffer(DWORD count, IMFMediaBuffer **buffer) { return mf.buffer(count, buffer); }
HRESULT media_aligned_buffer(DWORD count, DWORD alignment, IMFMediaBuffer **buffer) {
    return mf.aligned(count, alignment, buffer);
}
