/*
 * proc.c -- machteld's process-control bridge: the ::machteld::run verb over the
 * winjob substrate.
 *
 * Machteldproc_Init establishes the root KILL_ON_JOB_CLOSE job (nothing outlives
 * machteld) and registers ::machteld::run. Each run:
 *   - resolves the program on PATH (+ PATHEXT),
 *   - opens a nested job for tree-kill and -mem/-cpu limits,
 *   - launches born-in-job with stdout/stderr captured through pipes that are
 *     DRAINED ON THREADS (so a child filling one pipe while we block on the other
 *     cannot deadlock),
 *   - honours a wall-clock -timeout by tree-killing the job,
 *   - returns a dict {exit status out err pid truncated}.
 *
 * A process that runs and exits nonzero is a normal dict result (status error).
 * Usage mistakes and launch failures throw a Tcl error with a structured
 * -errorcode {MACHTELD RUN <code>}.
 */
#include "winjob.h"
#include <tcl.h>

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <string.h>

/* ---- UTF-8 <-> UTF-16 -------------------------------------------------- */

static wchar_t *u8_to_u16(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (w == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n) <= 0) { free(w); return NULL; }
    return w;
}

static char *u16_to_u8(const wchar_t *w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *s = (char *)malloc((size_t)n);
    if (s == NULL) return NULL;
    if (WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL) <= 0) { free(s); return NULL; }
    return s;
}

/* ---- human-unit parsing ------------------------------------------------ */

/* "30s" / "500ms" / "2m" / "1h" / bare number (seconds) -> milliseconds; -1 bad. */
static long long parse_duration_ms(const char *s) {
    char *end;
    double v = strtod(s, &end);
    if (end == s || v < 0) return -1;
    while (*end == ' ') end++;
    if (strcmp(end, "ms") == 0) return (long long)v;
    if (*end == '\0' || strcmp(end, "s") == 0) return (long long)(v * 1000.0);
    if (strcmp(end, "m") == 0) return (long long)(v * 60000.0);
    if (strcmp(end, "h") == 0) return (long long)(v * 3600000.0);
    return -1;
}

/* "1G" / "512M" / "64K" / "1024" / "...B" -> bytes (1024-based); -1 bad. */
static long long parse_bytes(const char *s) {
    char *end;
    double v = strtod(s, &end);
    if (end == s || v < 0) return -1;
    while (*end == ' ') end++;
    unsigned long long mul = 1;
    char c = *end;
    if (c == 'K' || c == 'k') { mul = 1ULL << 10; end++; }
    else if (c == 'M' || c == 'm') { mul = 1ULL << 20; end++; }
    else if (c == 'G' || c == 'g') { mul = 1ULL << 30; end++; }
    if (*end == 'B' || *end == 'b') end++;
    if (*end != '\0') return -1;
    return (long long)(v * (double)mul);
}

/* ---- program resolution (PATH + PATHEXT) ------------------------------- */

/* True if prog's final path component contains a '.' (already has an extension). */
static int has_extension(const char *prog) {
    const char *base = prog;
    for (const char *c = prog; *c; c++) {
        if (*c == '/' || *c == '\\') base = c + 1;
    }
    return strchr(base, '.') != NULL;
}

static char *resolve_exe(const char *prog) {
    wchar_t *wp = u8_to_u16(prog);
    if (wp == NULL) return NULL;
    wchar_t buf[MAX_PATH * 2];
    wchar_t *fpart = NULL;
    char *result = NULL;

    /* An extension-less name resolves against the executable extensions
     * (cmd -> cmd.exe); a name that already has an extension is searched as-is.
     * We never search the BARE name with no extension appended -- that can match
     * a non-executable file in the current directory (as it did: C:\...\cmd). */
    const wchar_t *exts[4];
    int ne = 0;
    if (has_extension(prog)) {
        exts[ne++] = NULL;
    } else {
        exts[ne++] = L".exe";
        exts[ne++] = L".com";
        exts[ne++] = L".bat";
        exts[ne++] = L".cmd";
    }
    for (int e = 0; e < ne; e++) {
        DWORD n = SearchPathW(NULL, wp, exts[e], (DWORD)(sizeof(buf) / sizeof(buf[0])), buf, &fpart);
        if (n > 0 && n < sizeof(buf) / sizeof(buf[0])) {
            DWORD attr = GetFileAttributesW(buf);
            if (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY)) {
                result = u16_to_u8(buf);
                break;
            }
        }
    }
    free(wp);
    return result;
}

/* ---- pipe reader thread (drains fully; stores up to cap) --------------- */

typedef struct {
    HANDLE read;
    char  *buf;
    size_t cap;
    size_t len;
    int    truncated;
} reader_t;

static DWORD WINAPI reader_thread(LPVOID arg) {
    reader_t *r = (reader_t *)arg;
    char tmp[8192];
    DWORD got = 0;
    while (ReadFile(r->read, tmp, sizeof(tmp), &got, NULL) && got > 0) {
        if (r->len < r->cap) {
            size_t space = r->cap - r->len;
            size_t take = ((size_t)got < space) ? (size_t)got : space;
            memcpy(r->buf + r->len, tmp, take);
            r->len += take;
            if (take < (size_t)got) r->truncated = 1;
        } else {
            r->truncated = 1; /* keep draining so the child never blocks */
        }
    }
    return 0;
}

/* ---- error helper ------------------------------------------------------ */

static int run_error(Tcl_Interp *interp, const char *code, const char *msg) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg ? msg : "run failed", -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "RUN", code, (char *)NULL);
    return TCL_ERROR;
}

/* ---- ::machteld::run --------------------------------------------------- */

/* Client data for the run command: the root job, and whether machteld itself is
 * a member of it (which decides how children are born into jobs). */
typedef struct {
    wj_job *root;
    int     in_root;
} proc_ctx;

static int RunCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    proc_ctx *ctx = (proc_ctx *)cd;

    long long timeout_ms = -1; /* -1 => no timeout */
    unsigned long long mem = 0;
    unsigned long long cpu_100ns = 0;
    const char *dir = NULL;

    int i = 1;
    for (; i < objc; i++) {
        const char *a = Tcl_GetString(objv[i]);
        if (strcmp(a, "--") == 0) { i++; break; }
        if (a[0] != '-' || a[1] == '\0') break; /* command starts here */
        if (i + 1 >= objc) return run_error(interp, "usage", "option needs a value");
        const char *v = Tcl_GetString(objv[i + 1]);
        if (strcmp(a, "-timeout") == 0) {
            timeout_ms = parse_duration_ms(v);
            if (timeout_ms < 0) return run_error(interp, "badvalue", "bad -timeout value");
        } else if (strcmp(a, "-mem") == 0) {
            long long b = parse_bytes(v);
            if (b < 0) return run_error(interp, "badvalue", "bad -mem value");
            mem = (unsigned long long)b;
        } else if (strcmp(a, "-cpu") == 0) {
            long long d = parse_duration_ms(v);
            if (d < 0) return run_error(interp, "badvalue", "bad -cpu value");
            cpu_100ns = (unsigned long long)d * 10000ULL; /* ms -> 100ns ticks */
        } else if (strcmp(a, "-dir") == 0) {
            dir = v;
        } else {
            return run_error(interp, "usage", "unknown option");
        }
        i++;
    }

    int cargc = objc - i;
    if (cargc <= 0) return run_error(interp, "usage", "run ?-opt val ...? ?--? command ?arg ...?");

    const char **cargv = (const char **)malloc((size_t)cargc * sizeof(char *));
    for (int k = 0; k < cargc; k++) cargv[k] = Tcl_GetString(objv[i + k]);

    char *exe = resolve_exe(cargv[0]);
    if (exe == NULL) { free(cargv); return run_error(interp, "notfound", "command not found on PATH"); }

    int         result = TCL_ERROR;
    const char *err = NULL;
    HANDLE      outR = NULL, outW = NULL, errR = NULL, errW = NULL, nul = NULL;
    wj_job     *perjob = NULL;
    void       *proch = NULL;
    HANDLE      tOut = NULL, tErr = NULL;
    reader_t    ro = { 0 }, re = { 0 };
    int         pid = 0;

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = FALSE; /* the launcher makes inheritable dups of the write ends */
    if (!CreatePipe(&outR, &outW, &sa, 0) || !CreatePipe(&errR, &errW, &sa, 0)) {
        run_error(interp, "oserror", "CreatePipe failed");
        goto cleanup;
    }
    nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (nul == INVALID_HANDLE_VALUE) { nul = NULL; run_error(interp, "oserror", "open NUL failed"); goto cleanup; }

    perjob = wj_job_new(0, &err); /* root already gives die-with-parent */
    if (perjob == NULL) { run_error(interp, "oserror", err); goto cleanup; }
    if (mem || cpu_100ns) {
        wj_limits lim = { 0 };
        lim.process_memory_bytes = mem;
        lim.process_cpu_100ns = cpu_100ns;
        if (wj_job_set_limits(perjob, &lim, &err) != 0) { run_error(interp, "oserror", err); goto cleanup; }
    }

    /* If machteld is itself a member of root, children inherit root
     * automatically -- listing it again in JOB_LIST would be a double assignment
     * (ERROR_ACCESS_DENIED), so born into the per-command job only. Otherwise
     * born into both, root-first. */
    void *jobh[2];
    int njobs;
    if (ctx->in_root) {
        jobh[0] = wj_job_handle(perjob);
        njobs = 1;
    } else {
        jobh[0] = wj_job_handle(ctx->root);
        jobh[1] = wj_job_handle(perjob);
        njobs = 2;
    }
    wj_stdio io = { nul, outW, errW };
    if (wj_launch(exe, cargc, cargv, dir, jobh, njobs, &io, &pid, &proch, &err) != 0) {
        run_error(interp, "launch", err);
        goto cleanup;
    }

    /* The child holds its own inherited dups now; drop our write ends + stdin so
     * the read ends see EOF once the child exits. */
    CloseHandle(outW); outW = NULL;
    CloseHandle(errW); errW = NULL;
    CloseHandle(nul);  nul = NULL;

    size_t cap = 1u << 20; /* 1 MiB per stream */
    ro.read = outR; ro.cap = cap; ro.buf = (char *)malloc(cap);
    re.read = errR; re.cap = cap; re.buf = (char *)malloc(cap);
    tOut = CreateThread(NULL, 0, reader_thread, &ro, 0, NULL);
    tErr = CreateThread(NULL, 0, reader_thread, &re, 0, NULL);

    long long code = 0;
    int status_timeout = 0;
    unsigned wait_ms = (timeout_ms < 0) ? WJ_INFINITE : (unsigned)timeout_ms;
    int w = wj_wait_timeout(proch, wait_ms, &code, &err);
    if (w == 1) { /* timed out: tree-kill and reap */
        status_timeout = 1;
        wj_job_terminate(perjob, 1);
        w = wj_wait_timeout(proch, WJ_INFINITE, &code, &err);
    }
    if (w < 0) { run_error(interp, "oserror", err); goto cleanup; }

    if (tOut) WaitForSingleObject(tOut, INFINITE);
    if (tErr) WaitForSingleObject(tErr, INFINITE);

    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("exit", -1), Tcl_NewWideIntObj((Tcl_WideInt)code));
    const char *st = status_timeout ? "timeout" : (code == 0 ? "ok" : "error");
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("status", -1), Tcl_NewStringObj(st, -1));
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("out", -1), Tcl_NewStringObj(ro.buf ? ro.buf : "", (Tcl_Size)ro.len));
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("err", -1), Tcl_NewStringObj(re.buf ? re.buf : "", (Tcl_Size)re.len));
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("pid", -1), Tcl_NewIntObj(pid));
    Tcl_Obj *trunc = Tcl_NewListObj(0, NULL);
    if (ro.truncated) Tcl_ListObjAppendElement(interp, trunc, Tcl_NewStringObj("out", -1));
    if (re.truncated) Tcl_ListObjAppendElement(interp, trunc, Tcl_NewStringObj("err", -1));
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("truncated", -1), trunc);
    Tcl_SetObjResult(interp, d);
    result = TCL_OK;

cleanup:
    if (tOut) CloseHandle(tOut);
    if (tErr) CloseHandle(tErr);
    free(ro.buf);
    free(re.buf);
    if (proch) wj_proc_close(proch);
    if (perjob) wj_job_free(perjob);
    if (outR) CloseHandle(outR);
    if (errR) CloseHandle(errR);
    if (outW) CloseHandle(outW);
    if (errW) CloseHandle(errW);
    if (nul) CloseHandle(nul);
    free(exe);
    free(cargv);
    return result;
}

/* ---- registration ------------------------------------------------------ */

int Machteldproc_Init(Tcl_Interp *interp) {
    const char *err = NULL;
    wj_job *root = wj_job_new(1, &err); /* KILL_ON_JOB_CLOSE: nothing outlives machteld */
    if (root == NULL) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(err ? err : "root job creation failed", -1));
        return TCL_ERROR;
    }
    /* Put machteld itself in the root job so even processes NOT launched through
     * wj_launch inherit die-with-parent. If the OS refuses (already in a
     * non-nestable job), children are born into root explicitly instead. */
    const char *ignore = NULL;
    int in_root = (wj_job_assign(root, (void *)GetCurrentProcess(), &ignore) == 0);

    proc_ctx *ctx = (proc_ctx *)malloc(sizeof(*ctx));
    ctx->root = root;
    ctx->in_root = in_root;

    Tcl_Eval(interp, "namespace eval ::machteld {}");
    Tcl_CreateObjCommand(interp, "::machteld::run", RunCmd, ctx, NULL);
    Tcl_PkgProvide(interp, "machteld::proc", "0.1");
    return TCL_OK;
}
