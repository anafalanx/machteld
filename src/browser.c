/* Own browser start-up until its profile receipt and control channel are
 * established. Reattachment checks the original process and its loopback
 * listener before sending any browser protocol message. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <stdlib.h>
#include <string.h>
#include "tcl.h"
#include "winjob.h"
#include "wintext.h"

typedef struct StartupGuard {
    HANDLE job;
    const WCHAR *exe;
    DWORD root_pid;
    Tcl_WideInt root_stamp;
    struct StartupGuard *previous;
} StartupGuard;
static const char guard_key[] = "machteld.browser.startup";

static int same_executable(const WCHAR *selected, const WCHAR *actual) {
    const WCHAR *names[] = {selected, actual};
    BY_HANDLE_FILE_INFORMATION info[2];
    for (size_t i = 0; i < 2; ++i) {
        HANDLE file = CreateFileW(names[i], FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                 NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (file == INVALID_HANDLE_VALUE) return 0;
        BOOL ok = GetFileInformationByHandle(file, &info[i]);
        CloseHandle(file);
        if (!ok) return 0;
    }
    return info[0].dwVolumeSerialNumber == info[1].dwVolumeSerialNumber &&
        info[0].nFileIndexHigh == info[1].nFileIndexHigh && info[0].nFileIndexLow == info[1].nFileIndexLow;
}

static int fail(Tcl_Interp *ip, const char *code, const char *message) {
    Tcl_SetErrorCode(ip, "MACHTELD", "BROWSER", code, NULL);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(message, -1));
    return TCL_ERROR;
}

static Tcl_WideInt started(HANDLE process) {
    FILETIME start, end, kernel, user;
    if (!GetProcessTimes(process, &start, &end, &kernel, &user)) return 0;
    return (Tcl_WideInt)(((ULONGLONG)start.dwHighDateTime << 32) | start.dwLowDateTime);
}

static int callback(Tcl_Interp *ip, Tcl_Obj *prefix, DWORD pid, Tcl_WideInt stamp) {
    Tcl_Obj *cmd = Tcl_DuplicateObj(prefix);
    Tcl_IncrRefCount(cmd);
    int result = Tcl_ListObjAppendElement(ip, cmd, Tcl_NewWideIntObj(pid));
    if (result == TCL_OK) result = Tcl_ListObjAppendElement(ip, cmd, Tcl_NewWideIntObj(stamp));
    if (result == TCL_OK) result = Tcl_EvalObjEx(ip, cmd, TCL_EVAL_GLOBAL);
    Tcl_DecrRefCount(cmd);
    return result;
}

static int start_cmd(void *data, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void)data;
    if (objc != 5) return fail(ip, "usage", "expected browser argument list, receipt and readiness callbacks");
    Tcl_Size n;
    Tcl_Obj **args;
    if (Tcl_ListObjGetElements(ip, objv[2], &n, &args) != TCL_OK || n < 1 || n > 64)
        return fail(ip, "badvalue", "invalid browser argument list");
    Tcl_Obj *normalized = Tcl_FSGetNormalizedPath(ip, objv[1]);
    const WCHAR *exe = normalized ? Tcl_FSGetNativePath(normalized) : NULL;
    if (!exe) return fail(ip, "badvalue", "expected a local browser executable");
    const char *words[65];
    words[0] = Tcl_GetString(normalized);
    for (Tcl_Size i = 0; i < n; ++i) words[i+1] = Tcl_GetString(args[i]);
    char *line = wj_make_cmdline((int)n + 1, words);
    wchar_t *wide = line ? mt_utf8_to_wide(line) : NULL;
    free(line);
    if (!wide) return fail(ip, "badvalue", "invalid Unicode in browser arguments");

    HANDLE job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    STARTUPINFOEXW si = {0};
    si.StartupInfo.cb = sizeof(si);
    si.StartupInfo.dwFlags = STARTF_FORCEOFFFEEDBACK;
    SIZE_T size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &size);
    si.lpAttributeList = size ? malloc(size) : NULL;
    int initialized = si.lpAttributeList &&
        InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &size);
    PROCESS_INFORMATION pi = {0};
    int rc = TCL_ERROR;
    if (!job || !initialized ||
            !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) ||
            !UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                      &job, sizeof(job), NULL, NULL)) {
        fail(ip, "launch", "could not guard browser start-up");
    } else if (!CreateProcessW(exe, wide, NULL, NULL, FALSE,
                              CREATE_SUSPENDED | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
                              NULL, NULL, &si.StartupInfo, &pi)) {
        fail(ip, "launch", "Windows could not start the selected browser");
    } else {
        Tcl_WideInt stamp = started(pi.hProcess);
        if (!stamp) fail(ip, "launch", "could not identify the new browser process");
        else if (callback(ip, objv[3], pi.dwProcessId, stamp) == TCL_OK) {
            if (ResumeThread(pi.hThread) == (DWORD)-1) fail(ip, "launch", "could not resume the browser");
            else {
                StartupGuard guard = {job, exe, pi.dwProcessId, stamp, Tcl_GetAssocData(ip, guard_key, NULL)};
                Tcl_SetAssocData(ip, guard_key, NULL, &guard);
                int ready = callback(ip, objv[4], pi.dwProcessId, stamp);
                if (guard.previous) Tcl_SetAssocData(ip, guard_key, NULL, guard.previous);
                else Tcl_DeleteAssocData(ip, guard_key);
                if (ready == TCL_OK) {
                    limits.BasicLimitInformation.LimitFlags = 0;
                    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)))
                        fail(ip, "launch", "could not release the browser from startup supervision");
                    else rc = TCL_OK;
                }
            }
        }
    }
    if (rc != TCL_OK && pi.hProcess && job) {
        DWORD status;
        if (GetExitCodeProcess(pi.hProcess, &status) && status != STILL_ACTIVE) {
            Tcl_Obj *note = Tcl_ObjPrintf("\n    (browser process exit code 0x%08lx)", (unsigned long)status);
            Tcl_IncrRefCount(note);
            Tcl_AddErrorInfo(ip, Tcl_GetString(note));
            Tcl_DecrRefCount(note);
        }
        TerminateJobObject(job, 1);
    }
    if (pi.hThread) CloseHandle(pi.hThread);
    if (pi.hProcess) CloseHandle(pi.hProcess);
    if (job) CloseHandle(job);
    if (initialized) DeleteProcThreadAttributeList(si.lpAttributeList);
    free(si.lpAttributeList);
    free(wide);
    return rc;
}

static int listener_owner(Tcl_Interp *ip, DWORD port, DWORD *owner) {
    DWORD size = 0;
    DWORD error = GetExtendedTcpTable(NULL, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
    if (error != ERROR_INSUFFICIENT_BUFFER || !size)
        return fail(ip, "oserror", "could not query the local listener table");
    MIB_TCPTABLE_OWNER_PID *table = NULL;
    for (int attempt = 0; attempt < 4; ++attempt) {
        table = malloc(size);
        if (!table) return fail(ip, "oserror", "could not allocate the local listener table");
        error = GetExtendedTcpTable(table, &size, FALSE, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
        if (error == NO_ERROR) break;
        free(table); table = NULL;
        if (error != ERROR_INSUFFICIENT_BUFFER) break;
    }
    if (!table) return fail(ip, "oserror", "could not inspect the local listener table");
    *owner = 0;
    for (DWORD i = 0; i < table->dwNumEntries; ++i) {
        MIB_TCPROW_OWNER_PID row = table->table[i];
        if (ntohs((u_short)row.dwLocalPort) != port) continue;
        if (row.dwLocalAddr == htonl(INADDR_LOOPBACK) && (!*owner || *owner == row.dwOwningPid)) {
            *owner = row.dwOwningPid;
        } else if (row.dwLocalAddr == INADDR_ANY || row.dwLocalAddr == htonl(INADDR_LOOPBACK)) {
            free(table);
            return fail(ip, "ownership", "the control port does not belong exclusively to the selected browser");
        }
    }
    free(table);
    return TCL_OK;
}

/* Edge can start a second copy of its executable, then exit normally. During
 * startup only, the fresh job and the selected executable establish ownership
 * of that successor before we persist its exact PID and creation time. */
static int startup_owner_cmd(void *data, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void)data;
    Tcl_WideInt root, stamp;
    int port = 0;
    if ((objc != 3 && objc != 4) || Tcl_GetWideIntFromObj(NULL, objv[1], &root) != TCL_OK ||
        Tcl_GetWideIntFromObj(NULL, objv[2], &stamp) != TCL_OK ||
        (objc == 4 && (Tcl_GetIntFromObj(NULL, objv[3], &port) != TCL_OK || port < 1 || port > 65535)))
        return fail(ip, "badvalue", "invalid browser startup identity or port");
    StartupGuard *guard = Tcl_GetAssocData(ip, guard_key, NULL);
    while (guard && (guard->root_pid != root || guard->root_stamp != stamp)) guard = guard->previous;
    if (!guard) return fail(ip, "ownership", "browser startup guard has expired");
    if (!port) {
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
        if (!QueryInformationJobObject(guard->job, JobObjectBasicAccountingInformation, &info, sizeof(info), NULL))
            return fail(ip, "oserror", "could not inspect the browser startup job");
        Tcl_SetObjResult(ip, Tcl_NewBooleanObj(info.ActiveProcesses != 0));
        return TCL_OK;
    }
    DWORD owner;
    if (listener_owner(ip, (DWORD)port, &owner) != TCL_OK) return TCL_ERROR;
    if (!owner) return TCL_OK;
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, owner);
    BOOL member = FALSE;
    WCHAR image[32768];
    DWORD len = sizeof(image) / sizeof(*image);
    Tcl_WideInt creation = 0;
    if (process && IsProcessInJob(process, guard->job, &member) && member &&
            QueryFullProcessImageNameW(process, 0, image, &len) &&
            same_executable(guard->exe, image) &&
            WaitForSingleObject(process, 0) == WAIT_TIMEOUT) creation = started(process);
    if (process) CloseHandle(process);
    if (!creation) return fail(ip, "ownership", "the browser listener is outside the selected startup job or executable");
    Tcl_Obj *items[] = {Tcl_NewWideIntObj(owner), Tcl_NewWideIntObj(creation)};
    Tcl_SetObjResult(ip, Tcl_NewListObj(2, items));
    return TCL_OK;
}

static int peer_cmd(void *data, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void)data;
    Tcl_WideInt pid, stamp;
    int port = 0;
    if ((objc != 3 && objc != 4) || Tcl_GetWideIntFromObj(NULL, objv[1], &pid) != TCL_OK ||
            pid < 1 || (Tcl_WideUInt)pid > MAXDWORD ||
            Tcl_GetWideIntFromObj(NULL, objv[2], &stamp) != TCL_OK || stamp <= 0 ||
            (objc == 4 && (Tcl_GetIntFromObj(NULL, objv[3], &port) != TCL_OK || port < 1 || port > 65535)))
        return fail(ip, "badvalue", "invalid browser process identity or port");
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, (DWORD)pid);
    if (!process && GetLastError() != ERROR_INVALID_PARAMETER)
        return fail(ip, "ownership", "could not establish browser process ownership");
    int alive = process && started(process) == stamp && WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
    int rc = TCL_OK;
    if (alive && port) {
        DWORD owner;
        rc = listener_owner(ip, (DWORD)port, &owner);
        if (rc == TCL_OK && owner && owner != (DWORD)pid)
            rc = fail(ip, "ownership", "the control port belongs to a different process");
        if (rc == TCL_OK) Tcl_SetObjResult(ip, Tcl_NewBooleanObj(owner != 0));
    }
    else Tcl_SetObjResult(ip, Tcl_NewBooleanObj(alive));
    if (process) CloseHandle(process);
    return rc;
}

int Machteldbrowser_Init(Tcl_Interp *interp) {
    if (!Tcl_FindNamespace(interp, "::machteld", NULL, TCL_GLOBAL_ONLY) &&
            !Tcl_CreateNamespace(interp, "::machteld", NULL, NULL)) return TCL_ERROR;
    if (!Tcl_CreateObjCommand(interp, "::machteld::BrowserStart", start_cmd, NULL, NULL) ||
        !Tcl_CreateObjCommand(interp, "::machteld::BrowserStartupOwner", startup_owner_cmd, NULL, NULL) ||
        !Tcl_CreateObjCommand(interp, "::machteld::BrowserPeer", peer_cmd, NULL, NULL)) return TCL_ERROR;
    return TCL_OK;
}
