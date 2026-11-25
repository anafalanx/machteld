/* Adapted from Els src/windrop.c, revision 247d68d40ab2 (MIT).
 * The copyright and permission text is shipped in licenses/Ann-MIT.txt.
 * Each widget has its own callback. Queue ownership of the HDROP so that
 * neither Tcl code nor filesystem-path conversion runs in a native wndproc. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include "tk.h"
#include "tkPlatDecls.h"
#include "desktop_drop.h"
#include "wintext.h"

typedef struct {
    Tcl_Interp *ip;
    HWND window;
    Tcl_HashEntry *entry;
    Tcl_Obj *prefix;
    int already_accepted;
} drop_target;

typedef struct {
    Tcl_Event event;
    drop_target *target;
    HDROP files;
} drop_event;

static int failure(Tcl_Interp *ip, const char *code, const char *message) {
    Tcl_SetErrorCode(ip, "MACHTELD", "DESKTOP", code, NULL);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(message, -1));
    return TCL_ERROR;
}

static int collect_paths(Tcl_Interp *ip, HDROP files, Tcl_Obj *paths) {
    UINT count = DragQueryFileW(files, 0xffffffffu, NULL, 0);
    for (UINT i = 0; i < count; ++i) {
        UINT length = DragQueryFileW(files, i, NULL, 0);
        if (!length || length > INT_MAX)
            return failure(ip, "badvalue", "Explorer reported an invalid file name");
        WCHAR *wide = malloc(((size_t)length + 1) * sizeof(*wide));
        if (!wide) return failure(ip, "oserror", "could not allocate the dropped file name");
        UINT actual = DragQueryFileW(files, i, wide, length + 1);
        char *utf = actual == length ? mt_wide_to_utf8(wide, (int)length) : NULL;
        free(wide);
        if (!utf) return failure(ip, "badvalue", "Explorer reported a file name that cannot be represented in Tcl");
        Tcl_ListObjAppendElement(NULL, paths, Tcl_NewStringObj(utf, -1));
        free(utf);
    }
    return TCL_OK;
}

static int deliver(Tcl_Event *event, int flags) {
    if (!(flags & TCL_WINDOW_EVENTS)) return 0;
    drop_event *drop = (drop_event *)event;
    Tcl_Interp *ip = drop->target->ip;
    Tcl_Obj *cmd = Tcl_DuplicateObj(drop->target->prefix), *paths = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(cmd);
    Tcl_IncrRefCount(paths);
    Tcl_Preserve(ip);
    Tcl_InterpState saved = Tcl_SaveInterpState(ip, TCL_OK);
    if (!Tcl_InterpDeleted(ip)) {
        int rc = collect_paths(ip, drop->files, paths);
        DragFinish(drop->files);
        drop->files = NULL;
        if (rc == TCL_OK) rc = Tcl_ListObjAppendElement(ip, cmd, paths);
        /* The callback can unregister, destroy the widget, or delete its
         * interpreter. No target pointer is used after evaluation starts. */
        if (rc == TCL_OK) rc = Tcl_EvalObjEx(ip, cmd, TCL_EVAL_GLOBAL);
        if (rc != TCL_OK && !Tcl_InterpDeleted(ip)) Tcl_BackgroundException(ip, rc);
    } else {
        DragFinish(drop->files);
    }
    Tcl_DecrRefCount(paths);
    Tcl_DecrRefCount(cmd);
    if (Tcl_InterpDeleted(ip)) Tcl_DiscardInterpState(saved);
    else Tcl_RestoreInterpState(ip, saved);
    Tcl_Release(ip);
    return 1;
}

static int discard(Tcl_Event *event, void *data) {
    if (event->proc != deliver) return 0;
    drop_event *drop = (drop_event *)event;
    if (drop->target != data || !drop->files) return 0;
    DragFinish(drop->files);
    return 1;
}

static LRESULT CALLBACK subclass(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);

static void remove_target(drop_target *target) {
    RemoveWindowSubclass(target->window, subclass, (UINT_PTR)target);
    if (!target->already_accepted) DragAcceptFiles(target->window, FALSE);
    Tcl_DeleteHashEntry(target->entry);
    Tcl_DeleteEvents(discard, target);
    Tcl_DecrRefCount(target->prefix);
    Tcl_Free(target);
}

static LRESULT CALLBACK subclass(HWND window, UINT msg, WPARAM wparam, LPARAM lparam,
                                 UINT_PTR id, DWORD_PTR data) {
    (void)id;
    drop_target *target = (drop_target *)data;
    if (msg == WM_DROPFILES) {
        drop_event *drop = Tcl_Alloc(sizeof(*drop));
        drop->event.proc = deliver;
        drop->event.nextPtr = NULL;
        drop->target = target;
        drop->files = (HDROP)wparam;
        Tcl_QueueEvent(&drop->event, TCL_QUEUE_TAIL);
        return 0;
    }
    if (msg == WM_NCDESTROY) remove_target(target);
    return DefSubclassProc(window, msg, wparam, lparam);
}

void desktop_drops_free(Tcl_HashTable *targets) {
    Tcl_HashSearch search;
    Tcl_HashEntry *entry;
    while ((entry = Tcl_FirstHashEntry(targets, &search)) != NULL)
        remove_target(Tcl_GetHashValue(entry));
    Tcl_DeleteHashTable(targets);
}

int desktop_drop(Tcl_Interp *ip, Tcl_HashTable *targets, Tcl_Obj *widget, Tcl_Obj *prefix) {
    Tcl_Size size = 0, length;
    const char *name = Tcl_GetStringFromObj(widget, &length);
    if (!length || memchr(name, '\0', (size_t)length) || name[0] != '.')
        return failure(ip, "badvalue", "supply a Tk widget path");
    if (prefix && Tcl_ListObjLength(NULL, prefix, &size) != TCL_OK)
        return failure(ip, "badvalue", "drop callback must be a command prefix");
    if (!Tcl_PkgPresent(ip, "Tk", NULL, 0))
        return failure(ip, "notfound", "load Tk before registering a widget");
    Tk_Window main = Tk_MainWindow(ip);
    Tk_Window w = main ? Tk_NameToWindow(ip, name, main) : NULL;
    if (!w) return failure(ip, "notfound", "no such Tk widget in this interpreter");
    if (prefix && size) Tk_MakeWindowExist(w);
    Window xid = Tk_WindowId(w);
    HWND hwnd = xid ? Tk_GetHWND(xid) : NULL;
    Tcl_HashEntry *entry = hwnd ? Tcl_FindHashEntry(targets, (const char *)hwnd) : NULL;
    drop_target *target = entry ? Tcl_GetHashValue(entry) : NULL;
    if (!prefix) {
        if (target) Tcl_SetObjResult(ip, target->prefix);
        return TCL_OK;
    }
    if (!size) {
        if (target) remove_target(target);
        return TCL_OK;
    }
    DWORD pid = 0;
    if (!hwnd || GetWindowThreadProcessId(hwnd, &pid) != GetCurrentThreadId() || pid != GetCurrentProcessId())
        return failure(ip, "oserror", "could not obtain the local Tk widget window");
    if (target) {
        Tcl_DeleteEvents(discard, target);
        Tcl_IncrRefCount(prefix);
        Tcl_DecrRefCount(target->prefix);
        target->prefix = prefix;
        return TCL_OK;
    }
    target = Tcl_Alloc(sizeof(*target));
    target->ip = ip;
    target->window = hwnd;
    target->prefix = prefix;
    target->already_accepted = (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_ACCEPTFILES) != 0;
    if (!SetWindowSubclass(hwnd, subclass, (UINT_PTR)target, (DWORD_PTR)target)) {
        Tcl_Free(target);
        return failure(ip, "oserror", "Windows could not register this widget for drops");
    }
    int fresh;
    target->entry = Tcl_CreateHashEntry(targets, (const char *)hwnd, &fresh);
    Tcl_SetHashValue(target->entry, target);
    Tcl_IncrRefCount(prefix);
    DragAcceptFiles(hwnd, TRUE);
    return TCL_OK;
}
