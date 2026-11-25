/* Start menu and AppsFolder discovery and Shell icon conversion adapted from
 * Ann a3182710 (src/annindex.c and src/annicon.c), Copyright 2026 Vincent
 * Vercauteren. MIT notice: licenses/Ann-MIT.txt. */
#define COBJMACROS
#define INITGUID
#define WIN32_LEAN_AND_MEAN
#include <initguid.h>
#include <windows.h>
#include <objbase.h>
#include <shlobj.h>
#include <shlguid.h>
#include <shobjidl.h>
#include <shellapi.h>
#include <appmodel.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include "tk.h"
#include "desktop_apps.h"
#include "wintext.h"

typedef struct {
    int packaged;
    wchar_t *location;
    BY_HANDLE_FILE_INFORMATION stamp;
} application;

struct desktop_catalog {
    Tcl_HashTable targets;
};

typedef struct {
    desktop_catalog *catalog;
    const char *issuer;
    Tcl_Obj *rows;
} scan;

static int failure(Tcl_Interp *ip, const char *code, const char *message) {
    Tcl_SetErrorCode(ip, "MACHTELD", "DESKTOP", code, NULL);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(message, -1));
    return TCL_ERROR;
}

static int shell_error(Tcl_Interp *ip, const char *message, HRESULT error) {
    Tcl_SetErrorCode(ip, "MACHTELD", "DESKTOP", "oserror", NULL);
    Tcl_SetObjResult(ip, Tcl_ObjPrintf("%s (HRESULT 0x%08lx)", message, (unsigned long)error));
    return TCL_ERROR;
}

static void free_catalog(void *data) {
    desktop_catalog *catalog = data;
    Tcl_HashSearch search;
    for (Tcl_HashEntry *e = Tcl_FirstHashEntry(&catalog->targets, &search); e;
            e = Tcl_NextHashEntry(&search)) {
        application *app = Tcl_GetHashValue(e);
        free(app->location);
        Tcl_Free(app);
    }
    Tcl_DeleteHashTable(&catalog->targets);
    Tcl_Free(catalog);
}

void desktop_catalog_free(desktop_catalog *catalog) {
    if (catalog) Tcl_EventuallyFree(catalog, free_catalog);
}

static wchar_t *join(const wchar_t *prefix, const wchar_t *tail) {
    size_t p = wcslen(prefix), t = wcslen(tail);
    if (p + t + 2 > 32768) return NULL;
    wchar_t *path = malloc((p + t + 2) * sizeof(*path));
    if (path) swprintf(path, p + t + 2, L"%ls\\%ls", prefix, tail);
    return path;
}

static int same_shortcut(const BY_HANDLE_FILE_INFORMATION *a, const BY_HANDLE_FILE_INFORMATION *b) {
    return a->dwVolumeSerialNumber == b->dwVolumeSerialNumber &&
        a->nFileIndexHigh == b->nFileIndexHigh && a->nFileIndexLow == b->nFileIndexLow &&
        a->nFileSizeHigh == b->nFileSizeHigh && a->nFileSizeLow == b->nFileSizeLow &&
        !CompareFileTime(&a->ftLastWriteTime, &b->ftLastWriteTime);
}

static HANDLE open_shortcut(const wchar_t *path, BY_HANDLE_FILE_INFORMATION *stamp, DWORD share) {
    HANDLE h = CreateFileW(path, FILE_READ_ATTRIBUTES, share, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (h != INVALID_HANDLE_VALUE && (!GetFileInformationByHandle(h, stamp) ||
            (stamp->dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)))) {
        CloseHandle(h);
        h = INVALID_HANDLE_VALUE;
    }
    return h;
}

static void add(scan *s, int packaged, const wchar_t *source, const wchar_t *display,
                const BY_HANDLE_FILE_INFORMATION *stamp) {
    char *name = mt_wide_to_utf8(display, -1), *location = mt_wide_to_utf8(source, -1);
    if (!name || !location) {free(name); free(location); return;}
    const char *kind = packaged ? "store" : "shortcut";
    Tcl_Obj *key = Tcl_ObjPrintf("app%s:%s:", s->issuer, kind);
    Tcl_IncrRefCount(key);
    if (!packaged) {
        Tcl_AppendPrintfToObj(key, "%lx.%lx.%lx.%lx.%lx.%lx.%lx:", stamp->dwVolumeSerialNumber,
            stamp->nFileIndexHigh, stamp->nFileIndexLow, stamp->nFileSizeHigh, stamp->nFileSizeLow,
            stamp->ftLastWriteTime.dwHighDateTime, stamp->ftLastWriteTime.dwLowDateTime);
    }
    Tcl_AppendToObj(key, location, -1);
    int fresh;
    Tcl_HashEntry *entry = Tcl_CreateHashEntry(&s->catalog->targets, Tcl_GetString(key), &fresh);
    if (fresh) {
        application *a = Tcl_Alloc(sizeof(*a));
        *a = (application){ .packaged = packaged, .location = _wcsdup(source) };
        if (stamp) a->stamp = *stamp;
        if (!a->location) {
            Tcl_DeleteHashEntry(entry);
            Tcl_Free(a);
        } else {
            Tcl_SetHashValue(entry, a);
            Tcl_Obj *row = Tcl_NewDictObj();
            Tcl_DictObjPut(NULL, row, Tcl_NewStringObj("kind", -1), Tcl_NewStringObj(kind, -1));
            Tcl_DictObjPut(NULL, row, Tcl_NewStringObj("name", -1), Tcl_NewStringObj(name, -1));
            Tcl_DictObjPut(NULL, row, Tcl_NewStringObj("target", -1), key);
            Tcl_DictObjPut(NULL, row, Tcl_NewStringObj("source", -1), Tcl_NewStringObj(location, -1));
            Tcl_ListObjAppendElement(NULL, s->rows, row);
        }
    }
    Tcl_DecrRefCount(key);
    free(name);
    free(location);
}

static HRESULT shortcuts(scan *s, const wchar_t *dir, unsigned depth) {
    if (depth > 64) return HRESULT_FROM_WIN32(ERROR_DIRECTORY);
    wchar_t *pattern = join(dir, L"*");
    if (!pattern) return E_OUTOFMEMORY;
    WIN32_FIND_DATAW f;
    HANDLE find = FindFirstFileW(pattern, &f);
    DWORD error = GetLastError();
    free(pattern);
    if (find == INVALID_HANDLE_VALUE) {
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ||
                error == ERROR_ACCESS_DENIED) return S_OK;
        return HRESULT_FROM_WIN32(error);
    }
    HRESULT result = S_OK;
    do {
        if (!wcscmp(f.cFileName, L".") || !wcscmp(f.cFileName, L"..") ||
                (f.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) continue;
        int directory = (f.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        const wchar_t *ext = wcsrchr(f.cFileName, L'.');
        if (!directory && (!ext || _wcsicmp(ext, L".lnk"))) continue;
        wchar_t *path = join(dir, f.cFileName);
        if (!path) {result = E_OUTOFMEMORY; break;}
        if (directory) result = shortcuts(s, path, depth + 1);
        else {
            BY_HANDLE_FILE_INFORMATION stamp;
            HANDLE file = open_shortcut(path, &stamp, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
            if (file != INVALID_HANDLE_VALUE) {
                CloseHandle(file);
                IShellItem *item = NULL;
                PWSTR label = NULL;
                if (SUCCEEDED(SHCreateItemFromParsingName(path, NULL, &IID_IShellItem, (void **)&item))) {
                    IShellItem_GetDisplayName(item, SIGDN_NORMALDISPLAY, &label);
                    IShellItem_Release(item);
                }
                wchar_t fallback[MAX_PATH];
                size_t len = (size_t)(ext - f.cFileName);
                wmemcpy(fallback, f.cFileName, len);
                fallback[len] = 0;
                add(s, 0, path, label && *label ? label : fallback, &stamp);
                CoTaskMemFree(label);
            }
        }
        free(path);
        if (FAILED(result)) break;
    } while (FindNextFileW(find, &f));
    error = GetLastError();
    FindClose(find);
    return FAILED(result) || error == ERROR_NO_MORE_FILES ? result : HRESULT_FROM_WIN32(error);
}

static HRESULT installed_store(scan *s) {
    IShellItem *folder = NULL;
    IEnumShellItems *items = NULL;
    HRESULT result = SHGetKnownFolderItem(&FOLDERID_AppsFolder, KF_FLAG_DEFAULT, NULL,
                                          &IID_IShellItem, (void **)&folder);
    if (SUCCEEDED(result)) result = IShellItem_BindToHandler(folder, NULL, &BHID_EnumItems,
        &IID_IEnumShellItems, (void **)&items);
    if (SUCCEEDED(result)) {
        IShellItem *item;
        while ((result = IEnumShellItems_Next(items, 1, &item, NULL)) == S_OK) {
            PWSTR name = NULL, id = NULL;
            IShellItem_GetDisplayName(item, SIGDN_PARENTRELATIVEPARSING, &id);
            UINT32 family = 0, app = 0;
            if (id && ParseApplicationUserModelId(id, &family, NULL, &app, NULL) == ERROR_INSUFFICIENT_BUFFER &&
                    SUCCEEDED(IShellItem_GetDisplayName(item, SIGDN_NORMALDISPLAY, &name)) && name && *name)
                add(s, 1, id, name, NULL);
            CoTaskMemFree(name);
            CoTaskMemFree(id);
            IShellItem_Release(item);
        }
    }
    if (items) IEnumShellItems_Release(items);
    if (folder) IShellItem_Release(folder);
    return result;
}

static HRESULT com_start(void) {
    return CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
}

static int collect(Tcl_Interp *ip, const char *issuer, desktop_catalog **catalog,
                   const wchar_t *const *dirs, size_t count, int with_store) {
    scan s = {.catalog = Tcl_Alloc(sizeof(*s.catalog)), .issuer = issuer, .rows = Tcl_NewListObj(0, NULL)};
    Tcl_InitHashTable(&s.catalog->targets, TCL_STRING_KEYS);
    Tcl_IncrRefCount(s.rows);
    HRESULT result = S_OK;
    for (size_t i = 0; i < count && SUCCEEDED(result); ++i) result = shortcuts(&s, dirs[i], 0);
    if (SUCCEEDED(result) && with_store) result = installed_store(&s);
    if (SUCCEEDED(result)) {
        desktop_catalog_free(*catalog);
        *catalog = s.catalog;
        Tcl_SetObjResult(ip, s.rows);
    } else desktop_catalog_free(s.catalog);
    Tcl_DecrRefCount(s.rows);
    return SUCCEEDED(result) ? TCL_OK : shell_error(ip, "could not read the Windows application catalog", result);
}

int desktop_applications(Tcl_Interp *ip, const char *issuer, desktop_catalog **catalog) {
    HRESULT apartment = com_start();
    if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE)
        return shell_error(ip, "COM initialization failed", apartment);
    PWSTR user = NULL, common = NULL;
    HRESULT result = SHGetKnownFolderPath(&FOLDERID_StartMenu, KF_FLAG_DONT_VERIFY, NULL, &user);
    if (SUCCEEDED(result)) result = SHGetKnownFolderPath(&FOLDERID_CommonStartMenu, KF_FLAG_DONT_VERIFY, NULL, &common);
    const wchar_t *dirs[2] = {user, common};
    int rc = SUCCEEDED(result) ? collect(ip, issuer, catalog, dirs, 2, 1)
        : shell_error(ip, "could not locate the Windows Start menu", result);
    CoTaskMemFree(user);
    CoTaskMemFree(common);
    if (SUCCEEDED(apartment)) CoUninitialize();
    return rc;
}
static application *lookup(Tcl_Interp *ip, desktop_catalog *catalog, Tcl_Obj *token, HANDLE *file) {
    *file = INVALID_HANDLE_VALUE;
    Tcl_HashEntry *e = catalog ? Tcl_FindHashEntry(&catalog->targets, Tcl_GetString(token)) : NULL;
    application *a = e ? Tcl_GetHashValue(e) : NULL;
    if (a && !a->packaged) {
        BY_HANDLE_FILE_INFORMATION current;
        *file = open_shortcut(a->location, &current, FILE_SHARE_READ);
        if (*file == INVALID_HANDLE_VALUE || !same_shortcut(&current, &a->stamp)) {
            if (*file != INVALID_HANDLE_VALUE) CloseHandle(*file);
            a = NULL;
        }
    }
    if (!a) failure(ip, "notfound", "application selection is absent or has changed");
    return a;
}

int desktop_launch_app(Tcl_Interp *ip, desktop_catalog *catalog, Tcl_Obj *token) {
    HANDLE file;
    application *a = lookup(ip, catalog, token, &file);
    if (!a) return TCL_ERROR;
    HRESULT apartment = com_start(), result = apartment == RPC_E_CHANGED_MODE ? S_OK : apartment;
    if (SUCCEEDED(result) && a->packaged) {
        IApplicationActivationManager *manager = NULL;
        result = CoCreateInstance(&CLSID_ApplicationActivationManager, NULL, CLSCTX_LOCAL_SERVER,
            &IID_IApplicationActivationManager, (void **)&manager);
        if (SUCCEEDED(result)) {
            DWORD pid;
            result = IApplicationActivationManager_ActivateApplication(manager, a->location, NULL, AO_NONE, &pid);
            IApplicationActivationManager_Release(manager);
        }
    } else if (SUCCEEDED(result)) {
        SHELLEXECUTEINFOW invoke = {.cbSize = sizeof(invoke), .fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC,
            .lpVerb = L"open", .lpFile = a->location, .nShow = SW_SHOWNORMAL};
        result = ShellExecuteExW(&invoke) ? S_OK : HRESULT_FROM_WIN32(GetLastError());
    }
    if (SUCCEEDED(apartment)) CoUninitialize();
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    return SUCCEEDED(result) ? TCL_OK : shell_error(ip, "Windows could not launch the selected application", result);
}

/* Read a bounded, top-down Shell bitmap. The Shell returns premultiplied
 * BGRA, while a Tk photo needs straight alpha. */
static int fill_image(Tcl_Interp *ip, HBITMAP bitmap, Tk_PhotoHandle photo) {
    BITMAP bm;
    if (!GetObjectW(bitmap, sizeof(bm), &bm) || bm.bmWidth < 1 || bm.bmWidth > 512 ||
            bm.bmHeight < 1 || bm.bmHeight > 512) return failure(ip, "oserror", "invalid Shell icon dimensions");
    int w = bm.bmWidth, h = bm.bmHeight;
    BITMAPINFO bi = {.bmiHeader = {.biSize = sizeof(BITMAPINFOHEADER), .biWidth = w, .biHeight = -h,
        .biPlanes = 1, .biBitCount = 32, .biCompression = BI_RGB}};
    unsigned char *pixels = Tcl_Alloc((size_t)w * h * 4);
    HDC dc = GetDC(NULL);
    int lines = dc ? GetDIBits(dc, bitmap, 0, (UINT)h, pixels, &bi, DIB_RGB_COLORS) : 0;
    if (dc) ReleaseDC(NULL, dc);
    int rc = TCL_ERROR;
    if (lines == h) {
        for (int i = 0; i < w * h; i++) {
            unsigned char *pixel = pixels + i * 4;
            unsigned alpha = pixel[3];
            for (int c = 0; c < 3 && alpha > 0 && alpha < 255; c++) {
                unsigned v = (unsigned)pixel[c] * 255 / alpha;
                pixel[c] = (unsigned char)(v > 255 ? 255 : v);
            }
        }
        Tk_PhotoImageBlock block = {.pixelPtr = pixels, .width = w, .height = h,
            .pitch = w * 4, .pixelSize = 4, .offset = {2, 1, 0, 3}};
        rc = Tk_PhotoSetSize(ip, photo, w, h);
        if (rc == TCL_OK) rc = Tk_PhotoPutBlock(ip, photo, &block, 0, 0, w, h, TK_PHOTO_COMPOSITE_SET);
    } else failure(ip, "oserror", "could not read the Shell icon bitmap");
    Tcl_Free(pixels);
    return rc;
}

int desktop_app_icon(Tcl_Interp *ip, desktop_catalog *catalog, Tcl_Obj *token,
                     Tcl_Obj *photo_name, Tcl_Obj *size) {
    int pixels = 32;
    if (size && (Tcl_GetIntFromObj(NULL, size, &pixels) != TCL_OK || pixels < 8 || pixels > 256))
        return failure(ip, "badvalue", "icon size must be between 8 and 256 pixels");
    HANDLE file;
    application *a = lookup(ip, catalog, token, &file);
    if (!a) return TCL_ERROR;
    Tk_PhotoHandle photo = Tcl_PkgPresent(ip, "Tk", NULL, 0)
        ? Tk_FindPhoto(ip, Tcl_GetString(photo_name)) : NULL;
    if (!photo) {
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        return failure(ip, "badvalue", "expected an existing Tk photo image");
    }
    HRESULT apartment = com_start(), result = apartment == RPC_E_CHANGED_MODE ? S_OK : apartment;
    wchar_t *parsing = a->packaged ? join(L"shell:AppsFolder", a->location) : NULL;
    IShellItemImageFactory *factory = NULL;
    HBITMAP bitmap = NULL;
    if (SUCCEEDED(result)) result = a->packaged && !parsing ? E_OUTOFMEMORY :
        SHCreateItemFromParsingName(parsing ? parsing : a->location, NULL, &IID_IShellItemImageFactory, (void **)&factory);
    free(parsing);
    if (SUCCEEDED(result)) {
        result = IShellItemImageFactory_GetImage(factory, ((SIZE){pixels, pixels}), SIIGBF_ICONONLY, &bitmap);
        IShellItemImageFactory_Release(factory);
    }
    int rc = FAILED(result) || !bitmap ? shell_error(ip, "could not retrieve the application icon", result)
        : fill_image(ip, bitmap, photo);
    if (bitmap) DeleteObject(bitmap);
    if (SUCCEEDED(apartment)) CoUninitialize();
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (rc == TCL_OK) Tcl_SetObjResult(ip, photo_name);
    return rc;
}
