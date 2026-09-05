/*
 * ps.c -- ::machteld::mtps: see and signal processes machteld did NOT start.
 *
 * The execution core supervises children it launched: born-in-job, tree-kill,
 * caps, timeouts. It has no view of the machine at all -- `child list` returns
 * only machteld's own children. This is the other half: enumerate every
 * process, read what the OS will tell us about it, and terminate one by pid.
 *
 * WHAT DEGRADES, AND HOW. A normal token cannot open every process: protected
 * processes, services and anything at a higher integrity level refuse
 * PROCESS_QUERY_LIMITED_INFORMATION. Rather than failing the whole listing --
 * useless for a task manager, where the interesting rows are often exactly the
 * ones you cannot open -- an unreadable process still appears with the fields
 * the snapshot gives (pid, ppid, name, threads) and empty/zero for the rest,
 * plus `access` reporting whether the details are real. A field that reads 0
 * because we were denied must not look like a field that is genuinely 0.
 *
 * CPU IS CUMULATIVE, NOT A PERCENTAGE. A percentage is a rate, and a rate needs
 * two samples and a clock; computing it inside the verb would mean hidden state
 * and an answer that depends on when you last called. So `cpu` is total
 * kernel+user milliseconds since the process started, and a caller that wants a
 * percentage takes two readings and divides -- determinism over cleverness.
 */
#undef USE_TCL_STUBS
#include "machteld.h"

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

static int ps_error(Tcl_Interp *interp, const char *code, const char *msg) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "MTPS", code, (char *)NULL);
    return TCL_ERROR;
}

/* FILETIME is 100ns units. Windows epoch is 1601; Unix is 1970. */
static Tcl_WideInt ft_to_100ns(const FILETIME *ft) {
    ULARGE_INTEGER u;
    u.LowPart = ft->dwLowDateTime;
    u.HighPart = ft->dwHighDateTime;
    return (Tcl_WideInt)u.QuadPart;
}

static char *u16_to_u8_dup(const wchar_t *w) {
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *s = (char *)malloc((size_t)n);
    if (s == NULL) return NULL;
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
            w, -1, s, n, NULL, NULL) <= 0) {
        free(s);
        return NULL;
    }
    return s;
}

static void dict_put_str(Tcl_Obj *d, const char *k, const char *v) {
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj(k, -1), Tcl_NewStringObj(v ? v : "", -1));
}
static void dict_put_wide(Tcl_Obj *d, const char *k, Tcl_WideInt v) {
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj(k, -1), Tcl_NewWideIntObj(v));
}

/* One row. `snap` fields are always present; the rest need a handle. */
static Tcl_Obj *ps_row(DWORD pid, DWORD ppid, const wchar_t *name, DWORD threads) {
    Tcl_Obj *d = Tcl_NewDictObj();
    char *nm = u16_to_u8_dup(name);
    dict_put_wide(d, "pid", (Tcl_WideInt)pid);
    dict_put_wide(d, "ppid", (Tcl_WideInt)ppid);
    dict_put_str(d, "name", nm ? nm : "");
    free(nm);
    dict_put_wide(d, "threads", (Tcl_WideInt)threads);

    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (h == NULL) {
        /* Denied or gone. Say so, and leave the unreadable fields empty rather
         * than zero -- 0 bytes of memory and "unknown" must not look alike. */
        dict_put_wide(d, "access", 0);
        dict_put_str(d, "exe", "");
        dict_put_str(d, "mem", "");
        dict_put_str(d, "private", "");
        dict_put_str(d, "cpu", "");
        dict_put_str(d, "started", "");
        return d;
    }
    /* `access` means every detail query answered; a row can be opened and
     * still have a field the system declined, and that field reads empty. */
    int complete = 1;
    dict_put_wide(d, "access", 1);

    wchar_t *path = (wchar_t *)malloc(32768u * sizeof(wchar_t));
    DWORD n = 32768u;
    if (path != NULL && QueryFullProcessImageNameW(h, 0, path, &n)) {
        path[n] = L'\0';
        char *p = u16_to_u8_dup(path);
        dict_put_str(d, "exe", p ? p : "");
        if (p == NULL) complete = 0;
        free(p);
    } else {
        dict_put_str(d, "exe", "");
        complete = 0;
    }
    free(path);

    PROCESS_MEMORY_COUNTERS_EX pmc;
    memset(&pmc, 0, sizeof pmc);
    pmc.cb = sizeof pmc;
    if (GetProcessMemoryInfo(h, (PROCESS_MEMORY_COUNTERS *)&pmc, sizeof pmc)) {
        dict_put_wide(d, "mem", (Tcl_WideInt)pmc.WorkingSetSize);
        dict_put_wide(d, "private", (Tcl_WideInt)pmc.PrivateUsage);
    } else {
        dict_put_str(d, "mem", "");
        dict_put_str(d, "private", "");
        complete = 0;
    }

    FILETIME ftCreate, ftExit, ftKernel, ftUser;
    if (GetProcessTimes(h, &ftCreate, &ftExit, &ftKernel, &ftUser)) {
        Tcl_WideInt cpu100 = ft_to_100ns(&ftKernel) + ft_to_100ns(&ftUser);
        dict_put_wide(d, "cpu", cpu100 / 10000); /* milliseconds */
        /* Creation time as Unix epoch seconds, so Tcl's own `clock format`
         * reads it without anyone doing 1601 arithmetic at the call site. */
        Tcl_WideInt created = ft_to_100ns(&ftCreate);
        dict_put_wide(d, "started", (created - 116444736000000000LL) / 10000000LL);
    } else {
        dict_put_str(d, "cpu", "");
        dict_put_str(d, "started", "");
        complete = 0;
    }
    if (!complete) dict_put_wide(d, "access", 0);
    CloseHandle(h);
    return d;
}

/* Terminate one pid. Returns NULL on success, or a code for the caller to raise.
 *
 * THE CORPSE CASE. TerminateProcess on a process that has ALREADY exited fails
 * with ERROR_ACCESS_DENIED -- indistinguishable, at the call site, from a
 * genuinely protected process. Taken at face value that makes `mtps kill` tell you
 * to re-run as administrator when the thing you aimed at simply finished on its
 * own, which is both wrong and the likeliest case in a task manager: you click
 * End Task on the row that was already on its way out. Windows keeps a pid
 * reserved for as long as anyone holds a handle to the dead process, so the
 * window for this is not narrow. The exit code tells the two apart, so the query
 * right is asked for alongside TERMINATE and the failure is re-read before it is
 * reported. */
static const char *ps_kill_one(DWORD pid, unsigned code) {
    int can_query = 1;
    HANDLE h = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (h == NULL) {
        /* A token may be permitted to kill but not to inspect; ask for less. */
        can_query = 0;
        h = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
    }
    if (h == NULL) {
        DWORD e = GetLastError();
        if (e == ERROR_INVALID_PARAMETER) return "notfound";
        return "denied";
    }
    const char *r = NULL;
    if (!TerminateProcess(h, code)) {
        DWORD ec = 0;
        r = (can_query && GetExitCodeProcess(h, &ec) && ec != STILL_ACTIVE)
            ? "notfound" : "denied";
    }
    CloseHandle(h);
    return r;
}

typedef struct {
    DWORD pid;
    DWORD ppid;
    int depth;
} ps_node;

static int ps_depth_desc(const void *a, const void *b) {
    const ps_node *x = (const ps_node *)a;
    const ps_node *y = (const ps_node *)b;
    if (x->depth != y->depth) return y->depth - x->depth;
    return x->pid < y->pid ? -1 : x->pid > y->pid;
}

static int PsCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    static const char *const subs[] = { "list", "info", "kill", NULL };
    enum { LIST, INFO, KILL };
    int idx;
    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "subcommand ?arg ...?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", TCL_EXACT, &idx) != TCL_OK) return TCL_ERROR;

    /* `kill` has one exact optional word.  Reject missing/extra words before
     * PID conversion so every arity failure has the native MTPS contract. */
    if (idx == KILL && objc != 3 && objc != 4) {
        return ps_error(interp, "usage", "usage: mtps kill pid ?-tree?");
    }

    if (idx == LIST) {
        if (objc != 2) { Tcl_WrongNumArgs(interp, 2, objv, ""); return TCL_ERROR; }
        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == INVALID_HANDLE_VALUE) return ps_error(interp, "oserror", "cannot snapshot processes");
        PROCESSENTRY32W pe;
        pe.dwSize = sizeof pe;
        Tcl_Obj *out = Tcl_NewListObj(0, NULL);
        BOOL more = Process32FirstW(snap, &pe);
        if (more) {
            do {
                Tcl_ListObjAppendElement(interp, out,
                    ps_row(pe.th32ProcessID, pe.th32ParentProcessID, pe.szExeFile, pe.cntThreads));
            } while (Process32NextW(snap, &pe));
            if (GetLastError() != ERROR_NO_MORE_FILES) {
                CloseHandle(snap);
                return ps_error(interp, "oserror", "process enumeration failed");
            }
        } else if (GetLastError() != ERROR_NO_MORE_FILES) {
            CloseHandle(snap);
            return ps_error(interp, "oserror", "process enumeration failed");
        }
        CloseHandle(snap);
        Tcl_SetObjResult(interp, out);
        return TCL_OK;
    }

    if (objc < 3) { Tcl_WrongNumArgs(interp, 2, objv, "pid ?arg?"); return TCL_ERROR; }
    Tcl_WideInt wpid;
    if (Tcl_GetWideIntFromObj(interp, objv[2], &wpid) != TCL_OK) {
        return ps_error(interp, "badvalue", "pid must be an integer");
    }
    if (wpid < 0 || wpid > 0xFFFFFFFFLL) return ps_error(interp, "badvalue", "pid out of range");
    DWORD pid = (DWORD)wpid;

    if (idx == INFO) {
        if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "pid"); return TCL_ERROR; }
        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == INVALID_HANDLE_VALUE) return ps_error(interp, "oserror", "cannot snapshot processes");
        PROCESSENTRY32W pe;
        pe.dwSize = sizeof pe;
        Tcl_Obj *row = NULL;
        BOOL more = Process32FirstW(snap, &pe);
        if (more) {
            do {
                if (pe.th32ProcessID == pid) {
                    row = ps_row(pe.th32ProcessID, pe.th32ParentProcessID, pe.szExeFile, pe.cntThreads);
                    break;
                }
                more = Process32NextW(snap, &pe);
            } while (more);
            if (row == NULL && GetLastError() != ERROR_NO_MORE_FILES) {
                CloseHandle(snap);
                return ps_error(interp, "oserror", "process enumeration failed");
            }
        } else if (GetLastError() != ERROR_NO_MORE_FILES) {
            CloseHandle(snap);
            return ps_error(interp, "oserror", "process enumeration failed");
        }
        CloseHandle(snap);
        if (row == NULL) return ps_error(interp, "notfound", "no such process");
        Tcl_SetObjResult(interp, row);
        return TCL_OK;
    }

    /* KILL. -tree walks ONE snapshot and kills descendants before the root.
     * Best-effort by construction and documented as such: a tree that is still
     * forking can outrun any snapshot, and a pid that exits mid-walk may be
     * reused. For a tree machteld STARTED, `child kill` is exact instead --
     * the job object holds the whole tree by identity, not by pid. */
    if (idx != KILL) {
        return TCL_ERROR; /* unreachable: the exact index table is exhaustive */
    }
    int tree = 0;
    unsigned code = 1;
    if (objc == 4) {
        if (strcmp(Tcl_GetString(objv[3]), "-tree") != 0) {
            return ps_error(interp, "usage", "unknown option");
        }
        tree = 1;
    }
    if (pid == 0 || pid == 4) {
        return ps_error(interp, "denied", "the system process cannot be terminated");
    }

    Tcl_Obj *killed_list = Tcl_NewListObj(0, NULL);
    Tcl_Obj *failed_list = Tcl_NewListObj(0, NULL);
    if (tree) {
        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == INVALID_HANDLE_VALUE) return ps_error(interp, "oserror", "cannot snapshot processes");
        ps_node *nodes = NULL;
        size_t n = 0, cap = 0;
        PROCESSENTRY32W pe;
        pe.dwSize = sizeof pe;
        if (Process32FirstW(snap, &pe)) {
            do {
                if (n == cap) {
                    size_t next = cap ? cap * 2 : 256;
                    if (next < cap || next > SIZE_MAX / sizeof(*nodes)) {
                        free(nodes); CloseHandle(snap);
                        return ps_error(interp, "oserror", "process snapshot is too large");
                    }
                    ps_node *grown = (ps_node *)realloc(nodes, next * sizeof(*nodes));
                    if (grown == NULL) {
                        free(nodes); CloseHandle(snap);
                        return ps_error(interp, "oserror", "out of memory taking process snapshot");
                    }
                    nodes = grown;
                    cap = next;
                }
                nodes[n].pid = pe.th32ProcessID;
                nodes[n].ppid = pe.th32ParentProcessID;
                nodes[n].depth = nodes[n].pid == pid ? 0 : -1;
                n++;
            } while (Process32NextW(snap, &pe));
            if (GetLastError() != ERROR_NO_MORE_FILES) {
                free(nodes); CloseHandle(snap);
                return ps_error(interp, "oserror", "process enumeration failed");
            }
        } else if (GetLastError() != ERROR_NO_MORE_FILES) {
            free(nodes); CloseHandle(snap);
            return ps_error(interp, "oserror", "process enumeration failed");
        }
        CloseHandle(snap);
        /* Repeatedly assign depth from the selected root. This reaches an
         * arbitrary-depth snapshot without assuming enumeration order. */
        for (size_t pass = 0; pass < n; pass++) {
            int changed = 0;
            for (size_t i = 0; i < n; i++) {
                if (nodes[i].depth >= 0) continue;
                for (size_t j = 0; j < n; j++) {
                    if (nodes[j].depth >= 0 && nodes[i].ppid == nodes[j].pid &&
                            nodes[i].pid != 0 && nodes[i].pid != 4) {
                        nodes[i].depth = nodes[j].depth + 1;
                        changed = 1;
                        break;
                    }
                }
            }
            if (!changed) break;
        }
        qsort(nodes, n, sizeof(*nodes), ps_depth_desc);
        for (size_t i = 0; i < n; i++) {
            if (nodes[i].depth < 0 || nodes[i].pid == pid) continue;
            const char *err = ps_kill_one(nodes[i].pid, code);
            if (err == NULL) {
                Tcl_ListObjAppendElement(interp, killed_list,
                    Tcl_NewWideIntObj((Tcl_WideInt)nodes[i].pid));
            } else {
                Tcl_Obj *row = Tcl_NewDictObj();
                dict_put_wide(row, "pid", (Tcl_WideInt)nodes[i].pid);
                dict_put_str(row, "code", err);
                Tcl_ListObjAppendElement(interp, failed_list, row);
            }
        }
        free(nodes);
    }
    const char *err = ps_kill_one(pid, code);
    if (!tree && err != NULL) {
        return ps_error(interp, err,
            strcmp(err, "notfound") == 0 ? "no such process" : "cannot terminate that process");
    }
    if (err == NULL) {
        Tcl_ListObjAppendElement(interp, killed_list,
            Tcl_NewWideIntObj((Tcl_WideInt)pid));
    } else {
        Tcl_Obj *row = Tcl_NewDictObj();
        dict_put_wide(row, "pid", (Tcl_WideInt)pid);
        dict_put_str(row, "code", err);
        Tcl_ListObjAppendElement(interp, failed_list, row);
    }
    Tcl_Obj *result = Tcl_NewDictObj();
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("killed", -1), killed_list);
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("failed", -1), failed_list);
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
}

int Machteldps_Init(Tcl_Interp *interp) {
    if (Tcl_CreateObjCommand(interp, "::machteld::mtps", PsCmd, NULL, NULL) == NULL) {
        return TCL_ERROR;
    }
    if (Tcl_PkgProvide(interp, "machteld::ps", MACHTELD_VERSION) != TCL_OK) {
        Tcl_DeleteCommand(interp, "::machteld::mtps");
        return TCL_ERROR;
    }
    return TCL_OK;
}
