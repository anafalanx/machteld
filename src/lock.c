/* Cooperative cross-process ownership of a resource. The coordination file
 * persists; only its kernel byte-range lock represents ownership. */
#include <windows.h>
#include <inttypes.h>
#include <stdio.h>
#include "tcl.h"

static LONG64 serial;

static int
lock_error(Tcl_Interp *interp, const char *code, const char *message)
{
    Tcl_SetObjResult(interp, Tcl_NewStringObj(message, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "LOCK", code, NULL);
    return TCL_ERROR;
}

static int
lock_win_error(Tcl_Interp *interp, const char *action, DWORD error)
{
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("lock: cannot %s (Windows error %lu)",
            action, (unsigned long)error));
    Tcl_SetErrorCode(interp, "MACHTELD", "LOCK", "oserror", NULL);
    return TCL_ERROR;
}

/* Closing a handle releases any residual lock even when an interpreter is
 * torn down. Explicitly unlock first so another owner need not wait for
 * Windows' asynchronous cleanup after a close. */
static DWORD
release_handle(HANDLE handle)
{
    OVERLAPPED range = {0};
    DWORD error = ERROR_SUCCESS;
    if (!UnlockFileEx(handle, 0, 1, 0, &range)) {
        error = GetLastError();
    }
    if (!CloseHandle(handle) && error == ERROR_SUCCESS) {
        error = GetLastError();
    }
    return error;
}

static void
lock_state_delete(void *state, Tcl_Interp *interp)
{
    (void)interp;
    Tcl_HashTable *locks = state;
    Tcl_HashSearch search;
    for (Tcl_HashEntry *item = Tcl_FirstHashEntry(locks, &search); item != NULL;
            item = Tcl_NextHashEntry(&search)) {
        release_handle(Tcl_GetHashValue(item));
    }
    Tcl_DeleteHashTable(locks);
    Tcl_Free(locks);
}

static int
lock_try(Tcl_Interp *interp, Tcl_HashTable *locks, Tcl_Obj *path)
{
    Tcl_Size length;
    const Tcl_UniChar *chars = Tcl_GetUnicodeFromObj(path, &length);
    if (length == 0) {
        return lock_error(interp, "badvalue", "lock: a coordination file path is required");
    }
    for (Tcl_Size i = 0; i < length; i++) {
        if (chars[i] == 0 || (chars[i] >= 0xd800 && chars[i] <= 0xdfff)) {
            return lock_error(interp, "badvalue", "lock: path must be valid Unicode without NUL");
        }
    }

    Tcl_Obj *normalized = Tcl_FSGetNormalizedPath(interp, path);
    const wchar_t *native = normalized == NULL ? NULL : Tcl_FSGetNativePath(normalized);
    if (native == NULL) {
        return lock_error(interp, "badvalue", "lock: expected a native Windows file path");
    }
    /* No delete sharing: an active owner cannot be separated from a new
     * contender by replacing the coordination file. NULL security attributes
     * make the handle noninheritable. No writes or truncation are needed. */
    HANDLE handle = CreateFileW(native, GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (handle == INVALID_HANDLE_VALUE) {
        return lock_win_error(interp, "open coordination file", GetLastError());
    }

    BY_HANDLE_FILE_INFORMATION info;
    if (GetFileType(handle) != FILE_TYPE_DISK) {
        CloseHandle(handle);
        return lock_error(interp, "badvalue", "lock: expected a regular coordination file");
    }
    if (!GetFileInformationByHandle(handle, &info)) {
        DWORD error = GetLastError();
        CloseHandle(handle);
        return lock_win_error(interp, "inspect coordination file", error);
    }
    if (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) {
        CloseHandle(handle);
        return lock_error(interp, "badvalue", "lock: expected a regular coordination file");
    }

    OVERLAPPED range = {0};
    if (!LockFileEx(handle, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
            0, 1, 0, &range)) {
        DWORD error = GetLastError();
        CloseHandle(handle);
        if (error == ERROR_LOCK_VIOLATION) {
            Tcl_ResetResult(interp);
            return TCL_OK;
        }
        return lock_win_error(interp, "acquire coordination file lock", error);
    }

    /* The serial is process-wide so a token from one interpreter can never
     * release a different interpreter's lock with the same local index. */
    char name[64];
    snprintf(name, sizeof(name), "lock#%lu-%" PRIu64,
            (unsigned long)GetCurrentProcessId(), (uint64_t)InterlockedIncrement64(&serial));
    Tcl_Obj *token = Tcl_NewStringObj(name, -1);
    int fresh;
    Tcl_HashEntry *item = Tcl_CreateHashEntry(locks, token, &fresh);
    Tcl_SetHashValue(item, handle);
    Tcl_SetObjResult(interp, token);
    return TCL_OK;
}

static int
LockCmd(void *state, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    static const char *const operations[] = {"try", "release", NULL};
    int operation;
    if (objc != 3 || Tcl_GetIndexFromObj(interp, objv[1], operations,
            "operation", TCL_EXACT, &operation) != TCL_OK) {
        return lock_error(interp, "usage", "usage: lock try path | lock release token");
    }
    Tcl_HashTable *locks = state;
    if (operation == 0) {
        return lock_try(interp, locks, objv[2]);
    }

    Tcl_HashEntry *item = Tcl_FindHashEntry(locks, objv[2]);
    if (item == NULL) {
        return lock_error(interp, "nohandle", "lock: unknown or released lock token");
    }
    DWORD error = release_handle(Tcl_GetHashValue(item));
    Tcl_DeleteHashEntry(item);
    if (error != ERROR_SUCCESS) {
        return lock_win_error(interp, "release coordination file lock", error);
    }
    return TCL_OK;
}

int
Machteldlock_Init(Tcl_Interp *interp)
{
    if (Tcl_GetAssocData(interp, "machteld::lock", NULL) != NULL) {
        return TCL_OK;
    }
    if (Tcl_FindNamespace(interp, "::machteld", NULL, TCL_GLOBAL_ONLY) == NULL &&
            Tcl_CreateNamespace(interp, "::machteld", NULL, NULL) == NULL) {
        return TCL_ERROR;
    }
    Tcl_HashTable *locks = (Tcl_HashTable *)Tcl_Alloc(sizeof(Tcl_HashTable));
    Tcl_InitObjHashTable(locks);
    Tcl_SetAssocData(interp, "machteld::lock", lock_state_delete, locks);
    return Tcl_CreateObjCommand(interp, "::machteld::lock", LockCmd, locks, NULL)
            == NULL ? TCL_ERROR : TCL_OK;
}
