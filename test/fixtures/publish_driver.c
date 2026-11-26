/* Exercise the production publication and recovery code on real private files.
 * Seed the intermediate Windows states that ReplaceFileW can return. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "../../src/wintext.h"

enum Fault { TRANSIENT, PERSISTENT, RESTORE_PRIOR, RETAIN_PRIOR, FOREIGN_MARKER,
             INACCESSIBLE_MARKER, LOCKED_MARKER, UNKNOWN_PRIOR, EDIT_CANDIDATE,
             EDIT_DESTINATION, SWAP_CANDIDATE };
static enum Fault fault;
static int attempts;
static wchar_t *last_backup, *aside;
static HANDLE marker_reader = INVALID_HANDLE_VALUE;

static void require_win(BOOL ok, const char *action) {
    if (!ok) {
        fprintf(stderr, "cannot arrange %s (Windows error %lu)\n", action, (unsigned long)GetLastError());
        exit(2);
    }
}

static void write_fixture(LPCWSTR path, const char *bytes, DWORD disposition) {
    HANDLE h = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, disposition, FILE_ATTRIBUTE_NORMAL, NULL);
    require_win(h != INVALID_HANDLE_VALUE, "fixture write");
    DWORD size = (DWORD)strlen(bytes), wrote;
    require_win(WriteFile(h, bytes, size, &wrote, NULL) && wrote == size, "fixture bytes");
    require_win(CloseHandle(h), "fixture close");
}

static BOOL WINAPI replace_fault(LPCWSTR destination, LPCWSTR candidate, LPCWSTR backup,
                                 DWORD flags, LPVOID exclude, LPVOID reserved) {
    ++attempts;
    free(last_backup);
    last_backup = _wcsdup(backup);
    if (!last_backup) exit(2);
    DWORD error = ERROR_UNABLE_TO_REMOVE_REPLACED;
    switch (fault) {
    case TRANSIENT:
        if (attempts > 1) return ReplaceFileW(destination, candidate, backup, flags, exclude, reserved);
        break;
    case PERSISTENT:
    case INACCESSIBLE_MARKER:
        break;
    case RESTORE_PRIOR:
    case RETAIN_PRIOR:
        require_win(MoveFileExW(destination, backup, MOVEFILE_REPLACE_EXISTING), "prior at backup");
        if (fault == RETAIN_PRIOR) write_fixture(destination, "competitor", CREATE_NEW);
        error = ERROR_UNABLE_TO_MOVE_REPLACEMENT_2;
        break;
    case FOREIGN_MARKER:
    case UNKNOWN_PRIOR:
        if (fault == UNKNOWN_PRIOR) {
            require_win(MoveFileExW(destination, aside, 0), "prior outside known names");
            write_fixture(destination, "competitor", CREATE_NEW);
        }
        require_win(DeleteFileW(backup), "remove reservation");
        write_fixture(backup, "foreign", CREATE_NEW);
        break;
    case LOCKED_MARKER:
        marker_reader = CreateFileW(backup, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                    NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        require_win(marker_reader != INVALID_HANDLE_VALUE, "deny marker deletion");
        break;
    case EDIT_CANDIDATE:
    case EDIT_DESTINATION:
        write_fixture(fault == EDIT_CANDIDATE ? candidate : destination, "newer version", TRUNCATE_EXISTING);
        break;
    case SWAP_CANDIDATE:
        require_win(MoveFileExW(candidate, aside, 0), "move original candidate");
        write_fixture(candidate, "competing candidate", CREATE_NEW);
        break;
    }
    SetLastError(error);
    return FALSE;
}

/* Metadata queries normally bypass share-mode restrictions. Model an
 * explicit ACL denial only for the failed call's backup name. */
static HANDLE WINAPI probe_open(LPCWSTR path, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES security,
                                DWORD disposition, DWORD flags, HANDLE template) {
    if (fault == INACCESSIBLE_MARKER && last_backup && !wcscmp(path, last_backup) &&
            access == FILE_READ_ATTRIBUTES && disposition == OPEN_EXISTING) {
        SetLastError(ERROR_ACCESS_DENIED);
        return INVALID_HANDLE_VALUE;
    }
    return CreateFileW(path, access, share, security, disposition, flags, template);
}

#define ReplaceFileW replace_fault
#define CreateFileW probe_open
#include "../../src/publish.c"
#undef CreateFileW
#undef ReplaceFileW

static int begin_case(void *ctx, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void)ctx;
    static const char *const names[] = {"transient", "persistent", "restore", "retain", "foreign",
        "inaccessible", "locked", "unknown", "edit-candidate", "edit-destination", "swap-candidate", NULL};
    if (objc != 3) {Tcl_WrongNumArgs(ip, 1, objv, "case aside"); return TCL_ERROR;}
    int chosen;
    if (Tcl_GetIndexFromObj(ip, objv[1], names, "case", TCL_EXACT, &chosen) != TCL_OK) return TCL_ERROR;
    const wchar_t *path = Tcl_FSGetNativePath(objv[2]);
    if (!path) return TCL_ERROR;
    free(aside);
    aside = _wcsdup(path);
    if (!aside) exit(2);
    free(last_backup);
    last_backup = NULL;
    attempts = 0;
    fault = (enum Fault)chosen;
    return TCL_OK;
}

static int finish_case(void *ctx, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void)ctx;
    if (objc != 1) {Tcl_WrongNumArgs(ip, 1, objv, NULL); return TCL_ERROR;}
    if (marker_reader != INVALID_HANDLE_VALUE) {
        require_win(CloseHandle(marker_reader), "release marker reader");
        marker_reader = INVALID_HANDLE_VALUE;
    }
    Tcl_DString path;
    Tcl_DStringInit(&path);
    Tcl_WCharToUtfDString(last_backup ? last_backup : L"", -1, &path);
    Tcl_Obj *values[] = {Tcl_NewIntObj(attempts), Tcl_NewStringObj(Tcl_DStringValue(&path), Tcl_DStringLength(&path))};
    Tcl_DStringFree(&path);
    Tcl_SetObjResult(ip, Tcl_NewListObj(2, values));
    return TCL_OK;
}

static int fixture_id(void *ctx, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void)ctx;
    if (objc != 2) {Tcl_WrongNumArgs(ip, 1, objv, "path"); return TCL_ERROR;}
    const wchar_t *path = Tcl_FSGetNativePath(objv[1]);
    if (!path) return TCL_ERROR;
    HANDLE file = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    require_win(file != INVALID_HANDLE_VALUE, "read fixture identity");
    FILE_ID_INFO id;
    require_win(GetFileInformationByHandleEx(file, FileIdInfo, &id, sizeof id), "read file ID");
    require_win(CloseHandle(file), "close identity handle");
    Tcl_SetObjResult(ip, Tcl_NewByteArrayObj(id.FileId.Identifier, sizeof id.FileId.Identifier));
    return TCL_OK;
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 2) return 2;
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    char *executable = mt_wide_to_utf8(argv[0], -1);
    if (!executable) return 2;
    Tcl_FindExecutable(executable);
    free(executable);
    Tcl_Interp *ip = Tcl_CreateInterp();
    if (Machteldpublish_Init(ip) != TCL_OK) return 2;
    Tcl_CreateObjCommand(ip, "begin_case", begin_case, NULL, NULL);
    Tcl_CreateObjCommand(ip, "finish_case", finish_case, NULL, NULL);
    Tcl_CreateObjCommand(ip, "fixture_id", fixture_id, NULL, NULL);
    Tcl_DString text;
    Tcl_DStringInit(&text);
    Tcl_WCharToUtfDString(argv[1], -1, &text);
    int rc = Tcl_EvalFile(ip, Tcl_DStringValue(&text));
    Tcl_DStringFree(&text);
    if (rc != TCL_OK) fprintf(stderr, "%s\n", Tcl_GetStringResult(ip));
    free(aside);
    free(last_backup);
    Tcl_DeleteInterp(ip);
    Tcl_Finalize();
    return rc == TCL_OK ? 0 : 1;
}
