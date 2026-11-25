/* Opt-in metadata enumeration and local-content channels for Windows files. */
#undef USE_TCL_STUBS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <wchar.h>
#include "machteld.h"
#include "wintext.h"

static int files_error(Tcl_Interp *interp, const char *code, const char *message) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(message, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "FILES", code, NULL);
    return TCL_ERROR;
}

static int win_error(Tcl_Interp *interp, const char *operation, DWORD error) {
    const char *code = "oserror";
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) code = "notfound";
    else if (error == ERROR_ACCESS_DENIED || error == ERROR_CLOUD_FILE_ACCESS_DENIED) code = "denied";
    else if (error == ERROR_SHARING_VIOLATION || error == ERROR_LOCK_VIOLATION) code = "busy";
    else if (error == ERROR_FILE_OFFLINE || error == ERROR_CLOUD_FILE_PROVIDER_NOT_RUNNING ||
             error == ERROR_CLOUD_FILE_NETWORK_UNAVAILABLE || error == ERROR_REMOTE_STORAGE_NOT_ACTIVE) code = "offline";
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s (Windows error %lu)", operation, (unsigned long)error));
    Tcl_SetErrorCode(interp, "MACHTELD", "FILES", code, NULL);
    return TCL_ERROR;
}

static const wchar_t *native_path(Tcl_Interp *interp, Tcl_Obj *path) {
    Tcl_Size n;
    const Tcl_UniChar *text = Tcl_GetUnicodeFromObj(path, &n);
    for (Tcl_Size i = 0; i < n; ++i) {
        if (text[i] == 0 || (text[i] >= 0xd800 && text[i] <= 0xdfff)) {
            files_error(interp, "badvalue", "expected a Unicode path without NUL");
            return NULL;
        }
    }
    Tcl_Obj *normalized = n ? Tcl_FSGetNormalizedPath(interp, path) : NULL;
    const wchar_t *result = normalized ? Tcl_FSGetNativePath(normalized) : NULL;
    if (!result) files_error(interp, "badvalue", "expected a native Windows path");
    return result;
}

static int requires_recall(DWORD attr) {
    return (attr & (FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_RECALL_ON_OPEN |
                    FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS)) != 0;
}

/* Windows can disguise an actual cloud reparse point as a normal file.
 * Scope the documented visibility override to native metadata operations.
 * An application callback must always observe its own thread mode. */
typedef CHAR (NTAPI *SetPlaceholderMode)(CHAR);
static SetPlaceholderMode mode_api(void) {
    union {FARPROC address; SetPlaceholderMode fn;} api = {
        GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlSetThreadPlaceholderCompatibilityMode")
    };
    return api.fn;
}
static int mode_error(Tcl_Interp *interp) {
    return files_error(interp, "unsupported", "Windows cannot expose cloud placeholder metadata");
}

/* A directory result holds shared keys; callback mode retains one row at a time. */
static const char *const key_names[] = {
    "name", "size", "mtime", "filetime", "attributes", "reparsetag", "offline", "pinned"
};
#define KEY_COUNT (sizeof(key_names) / sizeof(key_names[0]))

static Tcl_Obj *entry_row(Tcl_Obj *const keys[], const WIN32_FIND_DATAW *fd) {
    char *name = mt_wide_to_utf8(fd->cFileName, -1);
    if (!name) return NULL;
    Tcl_WideUInt size = ((Tcl_WideUInt)fd->nFileSizeHigh << 32) | fd->nFileSizeLow;
    Tcl_WideUInt ticks = ((Tcl_WideUInt)fd->ftLastWriteTime.dwHighDateTime << 32) |
                         fd->ftLastWriteTime.dwLowDateTime;
    DWORD attr = fd->dwFileAttributes;
    Tcl_Obj *values[KEY_COUNT] = {
        Tcl_NewStringObj(name, -1), Tcl_NewWideUIntObj(size),
        Tcl_NewWideIntObj((Tcl_WideInt)(ticks / 10000000) - 11644473600LL),
        Tcl_NewWideUIntObj(ticks), Tcl_NewWideIntObj(attr),
        Tcl_NewWideIntObj((attr & FILE_ATTRIBUTE_REPARSE_POINT) ? fd->dwReserved0 : 0),
        Tcl_NewBooleanObj(requires_recall(attr)), Tcl_NewBooleanObj((attr & FILE_ATTRIBUTE_PINNED) != 0)
    };
    free(name);
    Tcl_Obj *row = Tcl_NewDictObj();
    for (size_t i = 0; i < KEY_COUNT; ++i) Tcl_DictObjPut(NULL, row, keys[i], values[i]);
    return row;
}

static int entries_cmd(void *client, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)client;
    if (objc != 2 && objc != 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "directory ?rowCommandPrefix?");
        return TCL_ERROR;
    }
    Tcl_Size n = 0;
    Tcl_Obj **prefix = NULL;
    if (objc == 3) {
        if (Tcl_ListObjGetElements(interp, objv[2], &n, &prefix) != TCL_OK) return TCL_ERROR;
        if (!n) return files_error(interp, "badvalue", "expected a nonempty row command prefix");
    }
    const wchar_t *dir = native_path(interp, objv[1]);
    if (!dir) return TCL_ERROR;
    size_t length = wcslen(dir);
    wchar_t *pattern = malloc((length + 3) * sizeof(*pattern));
    if (!pattern) return files_error(interp, "oserror", "out of memory");
    wcscpy(pattern, dir);
    if (length && dir[length - 1] != L'\\') pattern[length++] = L'\\';
    pattern[length] = L'*';
    pattern[length + 1] = L'\0';
    WIN32_FIND_DATAW fd;
    SetPlaceholderMode mode = mode_api();
    CHAR previous = mode ? mode(2) : -1; /* PHCM_EXPOSE_PLACEHOLDERS */
    if (previous < 0) {free(pattern); return mode_error(interp);}
    HANDLE find = FindFirstFileExW(pattern, FindExInfoBasic, &fd, FindExSearchNameMatch,
                                   NULL, FIND_FIRST_EX_LARGE_FETCH);
    DWORD error = find == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
    free(pattern);
    if (find == INVALID_HANDLE_VALUE) {
        mode(previous);
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_NO_MORE_FILES) {
            DWORD attr = GetFileAttributesW(dir);
            if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY)) {
                Tcl_SetObjResult(interp, n ? Tcl_NewIntObj(0) : Tcl_NewListObj(0, NULL));
                return TCL_OK;
            }
            if (attr == INVALID_FILE_ATTRIBUTES) error = GetLastError();
        }
        return win_error(interp, "enumerating directory", error);
    }
    Tcl_Obj *rows = Tcl_NewListObj(0, NULL), *keys[KEY_COUNT];
    Tcl_IncrRefCount(rows);
    for (size_t i = 0; i < KEY_COUNT; ++i) {
        keys[i] = Tcl_NewStringObj(key_names[i], -1);
        Tcl_IncrRefCount(keys[i]);
    }
    /* Copy and own callback words before executing arbitrary user commands. */
    Tcl_Obj **args = n ? Tcl_Alloc(((size_t)n + 1) * sizeof(*args)) : NULL;
    for (Tcl_Size i = 0; i < n; ++i) {args[i] = prefix[i]; Tcl_IncrRefCount(args[i]);}
    int rc = TCL_OK;
    Tcl_WideInt count = 0;
    do {
        if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
        Tcl_Obj *row = entry_row(keys, &fd);
        if (!row) {rc = files_error(interp, "badvalue", "directory entry has an invalid name"); break;}
        if (n) {
            args[n] = row;
            Tcl_IncrRefCount(row);
            mode(previous);
            rc = Tcl_EvalObjv(interp, n + 1, args, 0);
            /* A callback may deliberately choose a new thread mode. */
            previous = mode(2);
            Tcl_DecrRefCount(row);
            if (previous < 0) {rc = mode_error(interp); break;}
        } else {
            rc = Tcl_ListObjAppendElement(interp, rows, row);
        }
        if (rc != TCL_OK) break;
        ++count;
    } while (FindNextFileW(find, &fd));
    if (rc == TCL_OK) {
        error = GetLastError();
        if (error != ERROR_NO_MORE_FILES) rc = win_error(interp, "continuing directory enumeration", error);
    }
    FindClose(find);
    if (previous >= 0) mode(previous);
    if (rc == TCL_OK) Tcl_SetObjResult(interp, n ? Tcl_NewWideIntObj(count) : rows);
    for (Tcl_Size i = 0; i < n; ++i) Tcl_DecrRefCount(args[i]);
    if (args) Tcl_Free(args);
    for (size_t i = 0; i < KEY_COUNT; ++i) Tcl_DecrRefCount(keys[i]);
    Tcl_DecrRefCount(rows);
    return rc;
}

static int offline(Tcl_Interp *interp) {
    return files_error(interp, "offline", "file contents require recall or are not fully available locally");
}

/* cfapi.h isn't shipped with the pinned MinGW headers. These are the public
 * Windows SDK signatures of two read-only Cloud Files queries. Load the OS
 * library only when a cloud reparse tag is present. */
typedef struct { LARGE_INTEGER offset, length; } FileRange;
typedef HRESULT (WINAPI *RangeInfoFn)(HANDLE, int, LARGE_INTEGER, LARGE_INTEGER, void *, DWORD, DWORD *);
typedef DWORD (WINAPI *PlaceholderStateFn)(DWORD, DWORD);

static int check_cloud_data(Tcl_Interp *interp, HANDLE data, const FILE_ATTRIBUTE_TAG_INFO *info) {
    HMODULE module = LoadLibraryExW(L"cldapi.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return win_error(interp, "loading Windows Cloud Files API", GetLastError());
    union { FARPROC address; RangeInfoFn call; } range = {GetProcAddress(module, "CfGetPlaceholderRangeInfo")};
    union { FARPROC address; PlaceholderStateFn call; } state = {GetProcAddress(module, "CfGetPlaceholderStateFromAttributeTag")};
    int rc = TCL_OK;
    LARGE_INTEGER length;
    if (!range.address || !state.address) {
        rc = files_error(interp, "unsupported", "Windows Cloud Files residency queries are unavailable");
    } else if (!GetFileSizeEx(data, &length)) {
        rc = win_error(interp, "reading cloud file size", GetLastError());
    } else {
        DWORD flags = state.call(info->FileAttributes, info->ReparseTag);
        /* CF_PLACEHOLDER_STATE_PLACEHOLDER, PARTIAL and PARTIALLY_ON_DISK. */
        if (!(flags & 1u) || (flags & 0x30u)) {
            rc = offline(interp);
        } else if (length.QuadPart > 0) {
            LARGE_INTEGER start = {0};
            FileRange resident;
            DWORD returned = 0;
            /* One continuous ONDISK range must cover the entire stream. */
            HRESULT hr = range.call(data, 1, start, length, &resident, sizeof(resident), &returned);
            if (hr == HRESULT_FROM_WIN32(ERROR_MORE_DATA)) {
                rc = offline(interp);
            } else if (FAILED(hr)) {
                rc = win_error(interp, "checking local cloud data ranges",
                               HRESULT_FACILITY(hr) == FACILITY_WIN32 ? HRESULT_CODE(hr) : (DWORD)hr);
            } else if (returned != sizeof(resident) || resident.offset.QuadPart != 0 ||
                       resident.length.QuadPart < length.QuadPart) {
                rc = offline(interp);
            }
        }
    }
    FreeLibrary(module);
    return rc;
}

static int inspect_file(Tcl_Interp *interp, HANDLE h, FILE_ATTRIBUTE_TAG_INFO *info) {
    if (GetFileType(h) != FILE_TYPE_DISK) return files_error(interp, "unsupported", "expected a disk file");
    if (!GetFileInformationByHandleEx(h, FileAttributeTagInfo, info, sizeof(*info))) {
        return win_error(interp, "checking file attributes", GetLastError());
    }
    if (requires_recall(info->FileAttributes)) return offline(interp);
    if (info->FileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        return files_error(interp, "badvalue", "expected a regular file");
    }
    if ((info->FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
        (info->ReparseTag & ~(DWORD)IO_REPARSE_TAG_CLOUD_MASK) != (DWORD)IO_REPARSE_TAG_CLOUD) {
        return files_error(interp, "unsupported", "local read cannot verify this reparse point's contents");
    }
    return TCL_OK;
}

static int open_local_path(Tcl_Interp *interp, const wchar_t *path) {
    DWORD flags = FILE_FLAG_OPEN_NO_RECALL | FILE_FLAG_OPEN_REPARSE_POINT;
    HANDLE meta = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE |
                              FILE_SHARE_DELETE, NULL, OPEN_EXISTING, flags | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (meta == INVALID_HANDLE_VALUE) return win_error(interp, "opening file metadata", GetLastError());
    FILE_ATTRIBUTE_TAG_INFO info;
    int rc = inspect_file(interp, meta, &info);
    HANDLE data = INVALID_HANDLE_VALUE;
    if (rc == TCL_OK) {
        /* CreateFile accepts OPEN_NO_RECALL on this data open. ReOpenFile
         * rejects that flag with ERROR_INVALID_PARAMETER on tested Windows.
         * The name may have changed, so classify the actual data handle again.
         * Its share mode excludes writers, deleters and exclusive dehydration. */
        data = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                           flags | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
        if (data == INVALID_HANDLE_VALUE) rc = win_error(interp, "opening local file data", GetLastError());
    }
    CloseHandle(meta);
    if (rc != TCL_OK) return rc;
    rc = inspect_file(interp, data, &info);
    if (rc == TCL_OK && (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        rc = check_cloud_data(interp, data, &info);
    }
    if (rc != TCL_OK) {CloseHandle(data); return rc;}
    Tcl_Channel channel = Tcl_MakeFileChannel(data, TCL_READABLE);
    if (!channel) {CloseHandle(data); return files_error(interp, "oserror", "creating local read channel failed");}
    if (Tcl_SetChannelOption(interp, channel, "-translation", "binary") != TCL_OK) {
        Tcl_Close(NULL, channel);
        return TCL_ERROR;
    }
    Tcl_RegisterChannel(interp, channel);
    Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_GetChannelName(channel), -1));
    return TCL_OK;
}

static int openlocal_cmd(void *client, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)client;
    if (objc != 2) {Tcl_WrongNumArgs(interp, 1, objv, "path"); return TCL_ERROR;}
    const wchar_t *path = native_path(interp, objv[1]);
    if (!path) return TCL_ERROR;
    SetPlaceholderMode mode = mode_api();
    CHAR previous = mode ? mode(2) : -1;
    if (previous < 0) return mode_error(interp);
    int rc = open_local_path(interp, path);
    mode(previous);
    return rc;
}

int Machteldfiles_Init(Tcl_Interp *interp) {
    if (Tcl_IsSafe(interp)) return files_error(interp, "denied", "native files require a trusted interpreter");
    if (Tcl_EvalEx(interp, "namespace eval ::machteld::files {}", -1, TCL_EVAL_GLOBAL) != TCL_OK) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "::machteld::files::entries", entries_cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::machteld::files::openlocal", openlocal_cmd, NULL, NULL);
    return Tcl_PkgProvide(interp, "machteld::files", "1.0");
}
