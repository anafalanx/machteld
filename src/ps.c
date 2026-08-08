/*
 * ps.c -- ::machteld::ps: see and signal processes machteld did NOT start.
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
#include <tcl.h>

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <string.h>
#include <stdlib.h>

static int ps_error(Tcl_Interp *interp, const char *code, const char *msg) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "PS", code, (char *)NULL);
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
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *s = (char *)malloc((size_t)n);
    if (s == NULL) return NULL;
    if (WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL) <= 0) { free(s); return NULL; }
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
    dict_put_wide(d, "access", 1);

    wchar_t path[MAX_PATH * 2];
    DWORD n = (DWORD)(sizeof path / sizeof path[0]);
    if (QueryFullProcessImageNameW(h, 0, path, &n)) {
        char *p = u16_to_u8_dup(path);
        dict_put_str(d, "exe", p ? p : "");
        free(p);
    } else {
        dict_put_str(d, "exe", "");
    }

    PROCESS_MEMORY_COUNTERS_EX pmc;
    memset(&pmc, 0, sizeof pmc);
    pmc.cb = sizeof pmc;
    if (GetProcessMemoryInfo(h, (PROCESS_MEMORY_COUNTERS *)&pmc, sizeof pmc)) {
        dict_put_wide(d, "mem", (Tcl_WideInt)pmc.WorkingSetSize);
        dict_put_wide(d, "private", (Tcl_WideInt)pmc.PrivateUsage);
    } else {
        dict_put_str(d, "mem", "");
        dict_put_str(d, "private", "");
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
    }
    CloseHandle(h);
    return d;
}

/* Terminate one pid. Returns NULL on success, or a code for the caller to raise.
 *
 * THE CORPSE CASE. TerminateProcess on a process that has ALREADY exited fails
 * with ERROR_ACCESS_DENIED -- indistinguishable, at the call site, from a
 * genuinely protected process. Taken at face value that makes `ps kill` tell you
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

static int PsCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    static const char *const subs[] = { "list", "info", "kill", NULL };
    enum { LIST, INFO, KILL };
    int idx;
    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "subcommand ?arg ...?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", 0, &idx) != TCL_OK) return TCL_ERROR;

    if (idx == LIST) {
        if (objc != 2) { Tcl_WrongNumArgs(interp, 2, objv, ""); return TCL_ERROR; }
        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == INVALID_HANDLE_VALUE) return ps_error(interp, "oserror", "cannot snapshot processes");
        PROCESSENTRY32W pe;
        pe.dwSize = sizeof pe;
        Tcl_Obj *out = Tcl_NewListObj(0, NULL);
        if (Process32FirstW(snap, &pe)) {
            do {
                Tcl_ListObjAppendElement(interp, out,
                    ps_row(pe.th32ProcessID, pe.th32ParentProcessID, pe.szExeFile, pe.cntThreads));
            } while (Process32NextW(snap, &pe));
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
        if (Process32FirstW(snap, &pe)) {
            do {
                if (pe.th32ProcessID == pid) {
                    row = ps_row(pe.th32ProcessID, pe.th32ParentProcessID, pe.szExeFile, pe.cntThreads);
                    break;
                }
            } while (Process32NextW(snap, &pe));
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
    if (idx == KILL) { /* fallthrough guard for the generator's branch scan */ } else return TCL_ERROR; /* unreachable: the index table is exhaustive */
    int tree = 0;
    unsigned code = 1;
    for (int i = 3; i < objc; i++) {
        const char *a = Tcl_GetString(objv[i]);
        if (strcmp(a, "-tree") == 0) { tree = 1; continue; }
        return ps_error(interp, "usage", "unknown option");
    }
    if (pid == 0 || pid == 4) {
        return ps_error(interp, "denied", "the system process cannot be terminated");
    }

    int killed = 0;
    if (tree) {
        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == INVALID_HANDLE_VALUE) return ps_error(interp, "oserror", "cannot snapshot processes");
        DWORD *pids = NULL, *ppids = NULL;
        size_t n = 0, cap = 0;
        PROCESSENTRY32W pe;
        pe.dwSize = sizeof pe;
        if (Process32FirstW(snap, &pe)) {
            do {
                if (n == cap) {
                    cap = cap ? cap * 2 : 256;
                    pids  = (DWORD *)realloc(pids, cap * sizeof(DWORD));
                    ppids = (DWORD *)realloc(ppids, cap * sizeof(DWORD));
                    if (pids == NULL || ppids == NULL) break;
                }
                pids[n] = pe.th32ProcessID;
                ppids[n] = pe.th32ParentProcessID;
                n++;
            } while (Process32NextW(snap, &pe));
        }
        CloseHandle(snap);
        /* Repeatedly sweep for anything whose parent is already marked, so a
         * grandchild is reached whatever order the snapshot happened to be in. */
        char *mark = (char *)calloc(n ? n : 1, 1);
        for (size_t i = 0; i < n; i++) if (pids[i] == pid) mark[i] = 1;
        for (int pass = 0; pass < 64; pass++) {
            int changed = 0;
            for (size_t i = 0; i < n; i++) {
                if (mark[i]) continue;
                for (size_t j = 0; j < n; j++) {
                    if (mark[j] && ppids[i] == pids[j] && pids[i] != 0 && pids[i] != 4) {
                        mark[i] = 1; changed = 1; break;
                    }
                }
            }
            if (!changed) break;
        }
        /* Children first, so a parent cannot spawn a replacement after its own
         * death is observed. */
        for (size_t i = 0; i < n; i++) {
            if (mark[i] && pids[i] != pid) { if (ps_kill_one(pids[i], code) == NULL) killed++; }
        }
        free(pids); free(ppids); free(mark);
    }
    const char *err = ps_kill_one(pid, code);
    if (err != NULL && killed == 0) {
        return ps_error(interp, err,
            strcmp(err, "notfound") == 0 ? "no such process" : "cannot terminate that process");
    }
    if (err == NULL) killed++;
    Tcl_SetObjResult(interp, Tcl_NewIntObj(killed));
    return TCL_OK;
}

int Machteldps_Init(Tcl_Interp *interp) {
    Tcl_CreateObjCommand(interp, "::machteld::ps", PsCmd, NULL, NULL);
    Tcl_PkgProvide(interp, "machteld::ps", "0.1");
    return TCL_OK;
}
