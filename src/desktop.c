/* Window selection on this Tcl thread's Win32 desktop, and document opening. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include <objbase.h>
#include <shellapi.h>
#include <shlwapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "tcl.h"
#include "wintext.h"
#include "desktop_apps.h"
#include "desktop_drop.h"

typedef struct {
    HWND window;
    DWORD pid, tid;
    uintptr_t cookie;
    int seen;
    Tcl_HashEntry *by_name, *by_hwnd;
} selection;

typedef struct {
    Tcl_HashTable names, handles;
    Tcl_HashTable drops;
    ATOM property;
    char issuer[40];
    uintptr_t next;
    desktop_catalog *applications;
    int (WINAPI *caption)(HWND, WCHAR *, int);
} desktop_state;

static int fail(Tcl_Interp *ip, const char *code, const char *message) {
    Tcl_SetErrorCode(ip, "MACHTELD", "DESKTOP", code, NULL);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(message, -1));
    return TCL_ERROR;
}

static int win_error(Tcl_Interp *ip, const char *action, DWORD error) {
    Tcl_SetErrorCode(ip, "MACHTELD", "DESKTOP", "oserror", NULL);
    Tcl_SetObjResult(ip, Tcl_ObjPrintf("%s (Windows error %lu)", action, (unsigned long)error));
    return TCL_ERROR;
}

static int matches(const desktop_state *state, const selection *item) {
    DWORD pid = 0;
    return GetWindowThreadProcessId(item->window, &pid) == item->tid && pid == item->pid &&
        GetPropW(item->window, MAKEINTATOM(state->property)) == (HANDLE)item->cookie;
}

static void release_selection(desktop_state *state, selection *item) {
    if (matches(state, item)) RemovePropW(item->window, MAKEINTATOM(state->property));
    Tcl_DeleteHashEntry(item->by_name);
    Tcl_DeleteHashEntry(item->by_hwnd);
    Tcl_Free(item);
}

static void discard_absent(desktop_state *state, int all) {
    Tcl_HashSearch search;
    Tcl_HashEntry *entry = Tcl_FirstHashEntry(&state->handles, &search);
    while (entry) {
        selection *item = Tcl_GetHashValue(entry);
        entry = Tcl_NextHashEntry(&search);
        if (all || !item->seen) release_selection(state, item);
        else item->seen = 0;
    }
}

static void free_state(void *data) {
    desktop_state *state = data;
    discard_absent(state, 1);
    Tcl_DeleteHashTable(&state->names);
    Tcl_DeleteHashTable(&state->handles);
    if (state->property) GlobalDeleteAtom(state->property);
    desktop_catalog_free(state->applications);
    desktop_drops_free(&state->drops);
    Tcl_Free(state);
}

static void destroy_state(void *data) {
    Tcl_EventuallyFree(data, free_state);
}

static int initialize_property(desktop_state *state, Tcl_Interp *ip) {
    if (state->property) return TCL_OK;
    GUID unique;
    WCHAR wide[40];
    if (FAILED(CoCreateGuid(&unique)) || !StringFromGUID2(&unique, wide, 40))
        return fail(ip, "oserror", "could not create a window selection identifier");
    state->property = GlobalAddAtomW(wide);
    if (!state->property) return win_error(ip, "could not reserve a window property", GetLastError());
    FARPROC caption = GetProcAddress(GetModuleHandleW(L"user32.dll"), "InternalGetWindowText");
    static_assert(sizeof(caption) == sizeof(state->caption));
    memcpy(&state->caption, &caption, sizeof(caption));
    for (size_t i = 0; i < 39; ++i) state->issuer[i] = (char)wide[i];
    return TCL_OK;
}

/* HWND/PID/TID can all repeat when an application recreates one of its own
 * windows. The interpreter's atom names a numeric property on the original
 * window. Windows discards that window's property list when it is destroyed.
 * A window that refuses the property can still be listed without a token. */
static const char *select_window(desktop_state *state, HWND hwnd, DWORD pid, DWORD tid) {
    Tcl_HashEntry *found = Tcl_FindHashEntry(&state->handles, (char *)hwnd);
    if (found) {
        selection *item = Tcl_GetHashValue(found);
        if (matches(state, item)) {
            item->seen = 1;
            return Tcl_GetHashKey(&state->names, item->by_name);
        }
        release_selection(state, item);
    }
    if (state->next == UINTPTR_MAX) return "";
    uintptr_t cookie = ++state->next;
    if (!SetPropW(hwnd, MAKEINTATOM(state->property), (HANDLE)cookie)) return "";
    char name[100];
    snprintf(name, sizeof(name), "window%s-%llu", state->issuer, (unsigned long long)cookie);
    selection *item = Tcl_Alloc(sizeof(*item));
    *item = (selection){ .window = hwnd, .pid = pid, .tid = tid, .cookie = cookie, .seen = 1 };
    int fresh;
    item->by_name = Tcl_CreateHashEntry(&state->names, name, &fresh);
    item->by_hwnd = Tcl_CreateHashEntry(&state->handles, (char *)hwnd, &fresh);
    Tcl_SetHashValue(item->by_name, item);
    Tcl_SetHashValue(item->by_hwnd, item);
    if (!matches(state, item)) {
        release_selection(state, item);
        return "";
    }
    return Tcl_GetHashKey(&state->names, item->by_name);
}

static void put(Tcl_Obj *dict, const char *key, Tcl_Obj *value) {
    Tcl_DictObjPut(NULL, dict, Tcl_NewStringObj(key, -1), value);
}

static Tcl_Obj *text(const WCHAR *wide) {
    char *bytes = mt_wide_to_utf8(wide, -1);
    Tcl_Obj *value = Tcl_NewStringObj(bytes ? bytes : "", -1);
    free(bytes);
    return value;
}

typedef struct {
    desktop_state *state;
    Tcl_Obj *rows;
    WCHAR title[32768];
} enumeration;

static BOOL CALLBACK visit(HWND hwnd, LPARAM data) {
    enumeration *list = (enumeration *)data;
    LONG_PTR flags = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if (!IsWindowVisible(hwnd) || (GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_CHILD) ||
            (flags & (WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE)) ||
            (GetWindow(hwnd, GW_OWNER) && !(flags & WS_EX_APPWINDOW))) return TRUE;
    DWORD cloaked = 0;
    if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) &&
            cloaked) return TRUE;
    DWORD pid = 0, tid = GetWindowThreadProcessId(hwnd, &pid);
    WCHAR class_name[256];
    if (!tid || !GetClassNameW(hwnd, class_name, 256)) return TRUE;
    list->title[0] = 0;
    const char *name = select_window(list->state, hwnd, pid, tid);
    /* Read the window manager's caption without dispatching a callback into
     * Tcl or waiting for a hung GUI thread in this process. */
    if (list->state->caption) list->state->caption(hwnd, list->title, 32768);
    else if (pid != GetCurrentProcessId()) GetWindowTextW(hwnd, list->title, 32768);
    DWORD current = 0;
    if (GetWindowThreadProcessId(hwnd, &current) != tid || current != pid) return TRUE;
    Tcl_Obj *row = Tcl_NewDictObj();
    put(row, "token", Tcl_NewStringObj(name, -1));
    put(row, "title", text(list->title));
    put(row, "class", text(class_name));
    put(row, "pid", Tcl_NewWideIntObj(pid));
    put(row, "minimized", Tcl_NewBooleanObj(IsIconic(hwnd)));
    put(row, "foreground", Tcl_NewBooleanObj(GetForegroundWindow() == hwnd));
    Tcl_ListObjAppendElement(NULL, list->rows, row);
    return TRUE;
}

static int windows(desktop_state *state, Tcl_Interp *ip) {
    if (initialize_property(state, ip) != TCL_OK) return TCL_ERROR;
    enumeration *list = Tcl_Alloc(sizeof(*list));
    list->state = state;
    list->rows = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(list->rows);
    SetLastError(ERROR_SUCCESS);
    BOOL ok = EnumDesktopWindows(GetThreadDesktop(GetCurrentThreadId()), visit, (LPARAM)list);
    DWORD error = GetLastError();
    discard_absent(state, 0);
    if (ok || !error) Tcl_SetObjResult(ip, list->rows);
    Tcl_DecrRefCount(list->rows);
    Tcl_Free(list);
    return ok || !error ? TCL_OK : win_error(ip, "could not enumerate windows", error);
}

static int activate(desktop_state *state, Tcl_Interp *ip, Tcl_Obj *token) {
    Tcl_HashEntry *entry = Tcl_FindHashEntry(&state->names, Tcl_GetString(token));
    selection *item = entry ? Tcl_GetHashValue(entry) : NULL;
    if (!item || !matches(state, item)) {
        if (item) release_selection(state, item);
        return fail(ip, "notfound", "window selection expired");
    }
    if (IsIconic(item->window)) ShowWindowAsync(item->window, SW_RESTORE);
    if (!matches(state, item)) return fail(ip, "notfound", "window selection expired");
    BOOL accepted = SetForegroundWindow(item->window);
    if (!matches(state, item)) return fail(ip, "notfound", "window selection expired");
    Tcl_Obj *result = Tcl_NewDictObj();
    put(result, "requested", Tcl_NewBooleanObj(accepted));
    put(result, "foreground", Tcl_NewBooleanObj(GetForegroundWindow() == item->window));
    Tcl_SetObjResult(ip, result);
    return TCL_OK;
}

static int local_drive(const WCHAR *path) {
    if (!wcsncmp(path, L"\\\\?\\", 4)) path += 4;
    if (!((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')) ||
            path[1] != L':' || path[2] != L'\\') return 0;
    WCHAR root[] = {path[0], L':', L'\\', 0};
    return GetDriveTypeW(root) != DRIVE_REMOTE;
}

static int open_path(Tcl_Interp *ip, Tcl_Obj *path) {
    Tcl_Size length;
    const Tcl_UniChar *characters = Tcl_GetUnicodeFromObj(path, &length);
    if (!length) return fail(ip, "badvalue", "expected a local document path");
    for (Tcl_Size i = 0; i < length; ++i) {
        if (!characters[i] || (characters[i] >= 0xd800 && characters[i] <= 0xdfff))
            return fail(ip, "badvalue", "document paths require valid Unicode without NUL");
    }
    Tcl_Obj *normalized = Tcl_FSGetNormalizedPath(ip, path);
    const WCHAR *native = normalized ? Tcl_FSGetNativePath(normalized) : NULL;
    if (!native || !local_drive(native)) return fail(ip, "badvalue", "expected a local document path");
    HANDLE file = CreateFileW(native, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)
            return fail(ip, "notfound", "the document does not exist");
        if (error == ERROR_INVALID_NAME || error == ERROR_BAD_PATHNAME)
            return fail(ip, "badvalue", "expected a local document file path");
        return win_error(ip, "could not open the document", error);
    }
    BY_HANDLE_FILE_INFORMATION info;
    WCHAR resolved[32768];
    DWORD count = GetFinalPathNameByHandleW(file, resolved, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (!count || count >= 32768 || !GetFileInformationByHandle(file, &info)) {
        DWORD error = GetLastError();
        CloseHandle(file);
        return win_error(ip, "could not identify the document", error);
    }
    if (!local_drive(resolved) || GetFileType(file) != FILE_TYPE_DISK ||
            (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
        CloseHandle(file);
        return fail(ip, "badvalue", "expected a local document file");
    }
    /* The Els shell helper also passes the entire native path as lpFile and
     * balances COM initialization on the calling thread. */
    HRESULT apartment = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE) {
        CloseHandle(file);
        return win_error(ip, "could not initialize the Windows shell", (DWORD)apartment);
    }
    /* The Unknown ProgID invokes the Open With chooser. Return the agreed
     * missing-association error before dispatching that interactive fallback.
     * Query the ProgID so packaged apps and delegated verbs qualify as well. */
    const WCHAR *extension = PathFindExtensionW(native);
    DWORD size = 0;
    HRESULT association = AssocQueryStringW(ASSOCF_INIT_IGNOREUNKNOWN, ASSOCSTR_PROGID,
        *extension ? extension : L".", NULL, NULL, &size);
    if (FAILED(association)) {
        if (SUCCEEDED(apartment)) CoUninitialize();
        CloseHandle(file);
        if (association == HRESULT_FROM_WIN32(ERROR_NO_ASSOCIATION))
            return fail(ip, "noassociation", "Windows has no application associated with the document");
        return win_error(ip, "could not query the document association", (DWORD)association);
    }
    SHELLEXECUTEINFOW request = { .cbSize = sizeof(request), .fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC,
        .lpVerb = L"open", .lpFile = native, .nShow = SW_SHOWNORMAL };
    BOOL ok = ShellExecuteExW(&request);
    DWORD error = ok ? ERROR_SUCCESS : GetLastError();
    if (SUCCEEDED(apartment)) CoUninitialize();
    CloseHandle(file);
    if (ok) return TCL_OK;
    if (error == ERROR_NO_ASSOCIATION || (INT_PTR)request.hInstApp == SE_ERR_NOASSOC ||
            (INT_PTR)request.hInstApp == SE_ERR_ASSOCINCOMPLETE)
        return fail(ip, "noassociation", "Windows has no application associated with the document");
    return win_error(ip, "Windows could not open the document", error);
}

static int dispatch(desktop_state *state, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    static const char *const ops[] = {"windows", "activate", "open", "apps", "launch", "icon", "drop", NULL};
    int op;
    if (objc >= 2 && Tcl_GetIndexFromObj(NULL, objv[1], ops, "operation", TCL_EXACT, &op) == TCL_OK) {
        switch (op) {
            case 0: if (objc == 2) return windows(state, ip); break;
            case 1: if (objc == 3) return activate(state, ip, objv[2]); break;
            case 2: if (objc == 3) return open_path(ip, objv[2]); break;
            case 3:
                if (objc != 2) break;
                if (initialize_property(state, ip) != TCL_OK) return TCL_ERROR;
                return desktop_applications(ip, state->issuer, &state->applications);
            case 4: if (objc == 3) return desktop_launch_app(ip, state->applications, objv[2]); break;
            case 5:
                if (objc == 4 || objc == 5)
                    return desktop_app_icon(ip, state->applications, objv[2], objv[3], objc == 5 ? objv[4] : NULL);
                break;
            case 6:
                if (objc == 3 || objc == 4)
                    return desktop_drop(ip, &state->drops, objv[2], objc == 4 ? objv[3] : NULL);
                break;
        }
    }
    return fail(ip, "usage", "usage: desktop windows | activate token | open path | apps | launch target | icon target photo ?size? | drop widget ?commandPrefix?");
}

static int DesktopCmd(void *data, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    desktop_state *state = data;
    desktop_catalog *active = state->applications;
    /* Shell COM dispatch can pump messages. A reentrant refresh or command
     * deletion must preserve the selection that the outer request is using. */
    Tcl_Preserve(state);
    if (active) Tcl_Preserve(active);
    int rc = dispatch(state, ip, objc, objv);
    if (active) Tcl_Release(active);
    Tcl_Release(state);
    return rc;
}

int Machtelddesktop_Init(Tcl_Interp *interp) {
    if (!Tcl_FindNamespace(interp, "::machteld", NULL, TCL_GLOBAL_ONLY) &&
            !Tcl_CreateNamespace(interp, "::machteld", NULL, NULL)) return TCL_ERROR;
    desktop_state *state = Tcl_Alloc(sizeof(*state));
    memset(state, 0, sizeof(*state));
    Tcl_InitHashTable(&state->names, TCL_STRING_KEYS);
    Tcl_InitHashTable(&state->handles, TCL_ONE_WORD_KEYS);
    Tcl_InitHashTable(&state->drops, TCL_ONE_WORD_KEYS);
    if (!Tcl_CreateObjCommand(interp, "::machteld::desktop", DesktopCmd, state, destroy_state)) {
        destroy_state(state);
        return TCL_ERROR;
    }
    return TCL_OK;
}
