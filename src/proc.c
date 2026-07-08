/*
 * proc.c -- machteld's process-control bridge over the winjob substrate.
 *
 * Machteldproc_Init establishes the root KILL_ON_JOB_CLOSE job (nothing outlives
 * machteld) and registers the execution-core verbs:
 *
 *   ::machteld::run   ?-timeout t -mem b -cpu t -dir d? ?--? cmd ?arg...?
 *       blocking one-shot -> dict {exit status out err pid truncated}
 *   ::machteld::child start|wait|kill|info|list|close ...
 *       async supervised children, addressed by an opaque token
 *   ::machteld::wait  ?-any? token ...
 *       block until all (or any) of the given children exit
 *
 * A child is launched born-in-job into a per-command job (tree-kill + limits);
 * stdout/stderr are captured on drain threads (no pipe-buffer deadlock). `run`
 * and `child start` share one launch/reap core -- run just reaps immediately.
 * Usage/launch failures throw -errorcode {MACHTELD RUN <code>}; a nonzero exit
 * is a normal dict result.
 */
#include "winjob.h"
#include <tcl.h>

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef NTDDI_VERSION
#define NTDDI_VERSION 0x0A000006 /* NTDDI_WIN10_RS5: exposes the ConPTY API */
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

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

static long long parse_duration_ms(const char *s) {
    char *end;
    double v = strtod(s, &end);
    if (end == s || v < 0) return -1;
    while (*end == ' ') end++;
    /* A unit is REQUIRED. A bare number is rejected, so "100" can never be
     * silently read as 100 SECONDS when 100 ms was meant -- exactly the footgun
     * that made pty read -timeout 100 block for a hundred seconds. */
    if (strcmp(end, "ms") == 0) return (long long)v;
    if (strcmp(end, "s") == 0)  return (long long)(v * 1000.0);
    if (strcmp(end, "m") == 0)  return (long long)(v * 60000.0);
    if (strcmp(end, "h") == 0)  return (long long)(v * 3600000.0);
    return -1;
}

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
    /* Extension-less names resolve against the executable extensions
     * (cmd -> cmd.exe); a name with an extension is searched as-is. Never search
     * the bare name -- that can match a non-executable in the current directory. */
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
            r->truncated = 1;
        }
    }
    return 0;
}

/* ---- a supervised child ------------------------------------------------ */

typedef struct child_s {
    char            token[24];   /* "child#N"; empty for a run's transient child */
    wj_job         *job;         /* per-command job (tree-kill + limits) */
    void           *proc;        /* process handle; NULL once reaped */
    int             pid;
    HANDLE          outR, errR;  /* pipe read ends */
    HANDLE          tOut, tErr;  /* reader threads */
    reader_t        ro, re;      /* captured stdout/stderr */
    int             reaped;      /* wait/reap already collected the exit + output */
    int             killed;      /* was tree-killed by machteld (child kill) */
    int             timeout;     /* specifically: killed because -timeout elapsed */
    long long       exit_code;
    struct child_s *next;        /* registry chain */
} child_t;

/* Client data shared by the verbs: the root job, whether machteld is a member of
 * it (decides the born-in-job list), and the live-children registry. */
typedef struct {
    wj_job  *root;
    int      in_root;
    child_t *children;    /* singly-linked list of tracked children */
    int      counter;     /* child token sequence */
    struct pty_s *ptys;   /* singly-linked list of open ptys */
    int      pty_counter; /* pty token sequence */
} proc_ctx;

static child_t *registry_find(proc_ctx *ctx, const char *token) {
    for (child_t *c = ctx->children; c; c = c->next) {
        if (strcmp(c->token, token) == 0) return c;
    }
    return NULL;
}

static void registry_remove(proc_ctx *ctx, child_t *c) {
    child_t **pp = &ctx->children;
    while (*pp) {
        if (*pp == c) { *pp = c->next; c->next = NULL; return; }
        pp = &(*pp)->next;
    }
}

/* ---- option parsing (shared by run and child start) -------------------- */

typedef struct {
    long long          timeout_ms; /* -1 = none */
    unsigned long long mem;
    unsigned long long cpu_100ns;
    const char        *dir;
    int                cmd_index;  /* objv index where the command begins */
} run_opts;

static int run_error(Tcl_Interp *interp, const char *code, const char *msg) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg ? msg : "run failed", -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "RUN", code, (char *)NULL);
    return TCL_ERROR;
}

static int parse_opts(Tcl_Interp *interp, int objc, Tcl_Obj *const objv[], int i0, run_opts *o) {
    o->timeout_ms = -1;
    o->mem = 0;
    o->cpu_100ns = 0;
    o->dir = NULL;
    int i = i0;
    for (; i < objc; i++) {
        const char *a = Tcl_GetString(objv[i]);
        if (strcmp(a, "--") == 0) { i++; break; }
        if (a[0] != '-' || a[1] == '\0') break;
        if (i + 1 >= objc) return run_error(interp, "usage", "option needs a value");
        const char *v = Tcl_GetString(objv[i + 1]);
        if (strcmp(a, "-timeout") == 0) {
            o->timeout_ms = parse_duration_ms(v);
            if (o->timeout_ms < 0) return run_error(interp, "badvalue", "bad -timeout value");
        } else if (strcmp(a, "-mem") == 0) {
            long long b = parse_bytes(v);
            if (b < 0) return run_error(interp, "badvalue", "bad -mem value");
            o->mem = (unsigned long long)b;
        } else if (strcmp(a, "-cpu") == 0) {
            long long d = parse_duration_ms(v);
            if (d < 0) return run_error(interp, "badvalue", "bad -cpu value");
            o->cpu_100ns = (unsigned long long)d * 10000ULL;
        } else if (strcmp(a, "-dir") == 0) {
            o->dir = v;
        } else {
            return run_error(interp, "usage", "unknown option");
        }
        i++;
    }
    o->cmd_index = i;
    return TCL_OK;
}

/* ---- launch / reap / dict / free (shared core) ------------------------- */

/* Launch cargv born-in-job with captured stdout/stderr. On success returns the
 * child (readers running, not yet reaped); on failure returns NULL and sets
 * *err. `track` registers it under a token; otherwise it is a transient run. */
static child_t *child_launch(proc_ctx *ctx, run_opts *o, int cargc, const char **cargv,
                             int track, const char **err) {
    char *exe = resolve_exe(cargv[0]);
    if (exe == NULL) { *err = "command not found on PATH"; return NULL; }

    child_t *c = (child_t *)calloc(1, sizeof(*c));
    HANDLE outW = NULL, errW = NULL, nul = NULL;
    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = FALSE;

    if (!CreatePipe(&c->outR, &outW, &sa, 0) || !CreatePipe(&c->errR, &errW, &sa, 0)) {
        *err = "CreatePipe failed";
        goto fail;
    }
    nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (nul == INVALID_HANDLE_VALUE) { nul = NULL; *err = "open NUL failed"; goto fail; }

    c->job = wj_job_new(0, err);
    if (c->job == NULL) goto fail;
    if (o->mem || o->cpu_100ns) {
        wj_limits lim = { 0 };
        lim.process_memory_bytes = o->mem;
        lim.process_cpu_100ns = o->cpu_100ns;
        if (wj_job_set_limits(c->job, &lim, err) != 0) goto fail;
    }

    void *jobh[2];
    int njobs;
    if (ctx->in_root) {
        jobh[0] = wj_job_handle(c->job);
        njobs = 1;
    } else {
        jobh[0] = wj_job_handle(ctx->root);
        jobh[1] = wj_job_handle(c->job);
        njobs = 2;
    }
    wj_stdio io = { nul, outW, errW };
    if (wj_launch(exe, cargc, cargv, o->dir, jobh, njobs, &io, 0, &c->pid, &c->proc, err) != 0) goto fail;

    CloseHandle(outW); outW = NULL;
    CloseHandle(errW); errW = NULL;
    CloseHandle(nul);  nul = NULL;

    size_t cap = 1u << 20;
    c->ro.read = c->outR; c->ro.cap = cap; c->ro.buf = (char *)malloc(cap);
    c->re.read = c->errR; c->re.cap = cap; c->re.buf = (char *)malloc(cap);
    c->tOut = CreateThread(NULL, 0, reader_thread, &c->ro, 0, NULL);
    c->tErr = CreateThread(NULL, 0, reader_thread, &c->re, 0, NULL);

    free(exe);
    if (track) {
        snprintf(c->token, sizeof c->token, "child#%d", ++ctx->counter);
        c->next = ctx->children;
        ctx->children = c;
    }
    return c;

fail:
    if (outW) CloseHandle(outW);
    if (errW) CloseHandle(errW);
    if (nul) CloseHandle(nul);
    if (c->outR) CloseHandle(c->outR);
    if (c->errR) CloseHandle(c->errR);
    if (c->job) wj_job_free(c->job);
    free(exe);
    free(c);
    return NULL;
}

/* Wait up to wait_ms; 0 = reaped (exit + output collected), 1 = timeout, -1 err. */
static int child_reap(child_t *c, unsigned wait_ms, const char **err) {
    if (c->reaped) return 0;
    long long code = 0;
    int w = wj_wait_timeout(c->proc, wait_ms, &code, err);
    if (w == 1) return 1;
    if (w < 0) return -1;
    c->exit_code = code;
    if (c->tOut) { WaitForSingleObject(c->tOut, INFINITE); CloseHandle(c->tOut); c->tOut = NULL; }
    if (c->tErr) { WaitForSingleObject(c->tErr, INFINITE); CloseHandle(c->tErr); c->tErr = NULL; }
    if (c->proc) { wj_proc_close(c->proc); c->proc = NULL; }
    if (c->outR) { CloseHandle(c->outR); c->outR = NULL; }
    if (c->errR) { CloseHandle(c->errR); c->errR = NULL; }
    c->reaped = 1;
    return 0;
}

static Tcl_Obj *child_dict(Tcl_Interp *interp, child_t *c) {
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("exit", -1), Tcl_NewWideIntObj((Tcl_WideInt)c->exit_code));
    const char *st = c->timeout ? "timeout" : c->killed ? "killed" : (c->exit_code == 0 ? "ok" : "error");
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("status", -1), Tcl_NewStringObj(st, -1));
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("out", -1), Tcl_NewStringObj(c->ro.buf ? c->ro.buf : "", (Tcl_Size)c->ro.len));
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("err", -1), Tcl_NewStringObj(c->re.buf ? c->re.buf : "", (Tcl_Size)c->re.len));
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("pid", -1), Tcl_NewIntObj(c->pid));
    Tcl_Obj *trunc = Tcl_NewListObj(0, NULL);
    if (c->ro.truncated) Tcl_ListObjAppendElement(interp, trunc, Tcl_NewStringObj("out", -1));
    if (c->re.truncated) Tcl_ListObjAppendElement(interp, trunc, Tcl_NewStringObj("err", -1));
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("truncated", -1), trunc);
    return d;
}

static void child_free(child_t *c) {
    if (c == NULL) return;
    if (!c->reaped) {
        if (c->job) wj_job_terminate(c->job, 1); /* kill so the pipes EOF and readers finish */
        const char *e = NULL;
        child_reap(c, WJ_INFINITE, &e);
    }
    free(c->ro.buf);
    free(c->re.buf);
    if (c->job) wj_job_free(c->job);
    free(c);
}

/* Build the command argv (UTF-8) from objv[cmd_index..objc). Caller frees. */
static const char **build_argv(Tcl_Interp *interp, int objc, Tcl_Obj *const objv[], int cmd_index, int *cargc) {
    int n = objc - cmd_index;
    if (n <= 0) return NULL;
    const char **cargv = (const char **)malloc((size_t)n * sizeof(char *));
    for (int k = 0; k < n; k++) cargv[k] = Tcl_GetString(objv[cmd_index + k]);
    *cargc = n;
    return cargv;
}

/* ---- ::machteld::run --------------------------------------------------- */

static int RunCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    proc_ctx *ctx = (proc_ctx *)cd;
    run_opts o;
    if (parse_opts(interp, objc, objv, 1, &o) != TCL_OK) return TCL_ERROR;
    int cargc = 0;
    const char **cargv = build_argv(interp, objc, objv, o.cmd_index, &cargc);
    if (cargv == NULL) return run_error(interp, "usage", "run ?-opt val ...? ?--? command ?arg ...?");

    const char *err = NULL;
    child_t *c = child_launch(ctx, &o, cargc, cargv, 0, &err);
    free(cargv);
    if (c == NULL) return run_error(interp, "launch", err);

    unsigned wait_ms = (o.timeout_ms < 0) ? WJ_INFINITE : (unsigned)o.timeout_ms;
    int w = child_reap(c, wait_ms, &err);
    if (w == 1) { /* timed out: tree-kill and reap */
        c->killed = 1;
        c->timeout = 1;
        wj_job_terminate(c->job, 1);
        w = child_reap(c, WJ_INFINITE, &err);
    }
    if (w < 0) { child_free(c); return run_error(interp, "oserror", err); }

    Tcl_SetObjResult(interp, child_dict(interp, c));
    child_free(c);
    return TCL_OK;
}

/* ---- ::machteld::child ------------------------------------------------- */

static int ChildCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    proc_ctx *ctx = (proc_ctx *)cd;
    static const char *const subs[] = { "start", "wait", "kill", "info", "list", "close", NULL };
    enum { START, WAIT, KILL, INFO, LIST, CLOSE };
    int idx;
    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "subcommand ?arg ...?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", 0, &idx) != TCL_OK) return TCL_ERROR;

    if (idx == START) {
        run_opts o;
        if (parse_opts(interp, objc, objv, 2, &o) != TCL_OK) return TCL_ERROR;
        int cargc = 0;
        const char **cargv = build_argv(interp, objc, objv, o.cmd_index, &cargc);
        if (cargv == NULL) return run_error(interp, "usage", "child start ?-opt val ...? ?--? command ?arg ...?");
        const char *err = NULL;
        child_t *c = child_launch(ctx, &o, cargc, cargv, 1, &err);
        free(cargv);
        if (c == NULL) return run_error(interp, "launch", err);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(c->token, -1));
        return TCL_OK;
    }

    if (idx == LIST) {
        Tcl_Obj *l = Tcl_NewListObj(0, NULL);
        for (child_t *c = ctx->children; c; c = c->next) {
            Tcl_ListObjAppendElement(interp, l, Tcl_NewStringObj(c->token, -1));
        }
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }

    /* the rest take a token */
    if (objc < 3) { Tcl_WrongNumArgs(interp, 2, objv, "token ?arg?"); return TCL_ERROR; }
    const char *token = Tcl_GetString(objv[2]);
    child_t *c = registry_find(ctx, token);
    if (c == NULL) return run_error(interp, "notfound", "no such child");

    switch (idx) {
    case WAIT: {
        const char *err = NULL;
        if (!c->reaped && child_reap(c, WJ_INFINITE, &err) < 0) return run_error(interp, "oserror", err);
        Tcl_SetObjResult(interp, child_dict(interp, c));
        return TCL_OK;
    }
    case KILL: {
        unsigned code = 1;
        if (objc >= 4) {
            int v;
            if (Tcl_GetIntFromObj(interp, objv[3], &v) != TCL_OK) return TCL_ERROR;
            code = (unsigned)v;
        }
        if (!c->reaped) { c->killed = 1; wj_job_terminate(c->job, code); }
        return TCL_OK;
    }
    case INFO: {
        Tcl_Obj *d = Tcl_NewDictObj();
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("token", -1), Tcl_NewStringObj(c->token, -1));
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("pid", -1), Tcl_NewIntObj(c->pid));
        int running = 0;
        if (c->reaped) {
            running = 0;
        } else {
            long long code = 0;
            const char *e = NULL;
            running = (wj_wait_timeout(c->proc, 0, &code, &e) == 1); /* 1 => still running */
        }
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("running", -1), Tcl_NewIntObj(running));
        if (c->reaped) {
            Tcl_DictObjPut(interp, d, Tcl_NewStringObj("exit", -1), Tcl_NewWideIntObj((Tcl_WideInt)c->exit_code));
        }
        Tcl_SetObjResult(interp, d);
        return TCL_OK;
    }
    case CLOSE:
        registry_remove(ctx, c);
        child_free(c); /* kills first if still running */
        return TCL_OK;
    }
    return TCL_OK;
}

/* ---- ::machteld::wait -------------------------------------------------- */

static int WaitCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    proc_ctx *ctx = (proc_ctx *)cd;
    int any = 0;
    int i = 1;
    if (i < objc && strcmp(Tcl_GetString(objv[i]), "-any") == 0) { any = 1; i++; }
    int n = objc - i;
    if (n <= 0) return run_error(interp, "usage", "wait ?-any? token ...");
    if (n > MAXIMUM_WAIT_OBJECTS) return run_error(interp, "usage", "too many children to wait on (max 64)");

    Tcl_Obj *done = Tcl_NewListObj(0, NULL);
    HANDLE h[MAXIMUM_WAIT_OBJECTS];
    child_t *cs[MAXIMUM_WAIT_OBJECTS];
    int nh = 0;
    for (int k = 0; k < n; k++) {
        const char *tok = Tcl_GetString(objv[i + k]);
        child_t *c = registry_find(ctx, tok);
        if (c == NULL) return run_error(interp, "notfound", "no such child");
        if (c->reaped) {
            Tcl_ListObjAppendElement(interp, done, Tcl_NewStringObj(tok, -1));
        } else {
            h[nh] = (HANDLE)c->proc;
            cs[nh] = c;
            nh++;
        }
    }
    /* -any and some are already done, or nothing left to wait on: return now. */
    if (nh == 0 || (any && Tcl_GetCharLength(done) > 0)) {
        Tcl_SetObjResult(interp, done);
        return TCL_OK;
    }
    DWORD r = WaitForMultipleObjects((DWORD)nh, h, any ? FALSE : TRUE, INFINITE);
    if (any) {
        if (r < WAIT_OBJECT_0 + (DWORD)nh) {
            Tcl_ListObjAppendElement(interp, done, Tcl_NewStringObj(cs[r - WAIT_OBJECT_0]->token, -1));
        }
    } else {
        for (int k = 0; k < nh; k++) {
            Tcl_ListObjAppendElement(interp, done, Tcl_NewStringObj(cs[k]->token, -1));
        }
    }
    Tcl_SetObjResult(interp, done);
    return TCL_OK;
}

/* ---- ::machteld::detach ------------------------------------------------ */

/* Launch a fire-and-forget daemon: NUL stdio (no capture), broken away from the
 * root job so it outlives machteld (CREATE_BREAKAWAY_FROM_JOB; where the OS
 * forbids breakaway it falls back to a normal launch and dies with machteld).
 * Not tracked -- returns the pid. */
static int DetachCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    run_opts o;
    if (parse_opts(interp, objc, objv, 1, &o) != TCL_OK) return TCL_ERROR;
    int cargc = 0;
    const char **cargv = build_argv(interp, objc, objv, o.cmd_index, &cargc);
    if (cargv == NULL) return run_error(interp, "usage", "detach ?-opt val ...? ?--? command ?arg ...?");
    char *exe = resolve_exe(cargv[0]);
    if (exe == NULL) { free(cargv); return run_error(interp, "notfound", "command not found on PATH"); }

    int         result = TCL_ERROR;
    const char *err = NULL;
    HANDLE      nul = NULL;
    wj_job     *djob = NULL;
    void       *proch = NULL;
    int         pid = 0;

    nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                      NULL, OPEN_EXISTING, 0, NULL);
    if (nul == INVALID_HANDLE_VALUE) { nul = NULL; run_error(interp, "oserror", "open NUL failed"); goto cleanup; }
    djob = wj_job_new(0, &err); /* plain job: closing our handle later won't kill it */
    if (djob == NULL) { run_error(interp, "oserror", err); goto cleanup; }
    if (o.mem || o.cpu_100ns) {
        wj_limits lim = { 0 };
        lim.process_memory_bytes = o.mem;
        lim.process_cpu_100ns = o.cpu_100ns;
        if (wj_job_set_limits(djob, &lim, &err) != 0) { run_error(interp, "oserror", err); goto cleanup; }
    }
    void *jobh[1] = { wj_job_handle(djob) };
    wj_stdio io = { nul, nul, nul };
    if (wj_launch(exe, cargc, cargv, o.dir, jobh, 1, &io, 1 /*breakaway*/, &pid, &proch, &err) != 0) {
        run_error(interp, "launch", err);
        goto cleanup;
    }
    Tcl_SetObjResult(interp, Tcl_NewIntObj(pid));
    result = TCL_OK;

cleanup:
    if (proch) wj_proc_close(proch); /* stop supervising; the daemon runs on */
    if (djob) wj_job_free(djob);      /* close our handle -- plain job, no kill */
    if (nul) CloseHandle(nul);
    free(exe);
    free(cargv);
    return result;
}

/* ---- ::machteld::pty (ConPTY) ------------------------------------------ *
 *
 * A ConPTY-backed child: the OS gives it a real pseudo-console (so isatty() is
 * true and it line-edits / colours / prompts as it would in a terminal), while
 * machteld drives its keyboard (send) and reads its screen (read) over two
 * pipes. Born-in-job like every other child, so it stays supervised. Output is
 * the raw VT/ANSI byte stream -- the `expect` loop matches on it as text;
 * clean-text terminal emulation is a later layer.
 */

typedef struct pty_s {
    char    token[24];
    HPCON   hpc;
    wj_job *job;
    void   *proc;
    int     pid;
    HANDLE  inW;  /* parent writes the child's input (keyboard) here */
    HANDLE  outR; /* parent reads the child's output (screen) here */
    struct pty_s *next;
} pty_t;

static pty_t *pty_find(proc_ctx *ctx, const char *token) {
    for (pty_t *p = ctx->ptys; p; p = p->next) {
        if (strcmp(p->token, token) == 0) return p;
    }
    return NULL;
}

/* Drain a pipe to EOF, discarding -- run on a thread during ClosePseudoConsole. */
static DWORD WINAPI pty_drain_thread(LPVOID arg) {
    HANDLE h = (HANDLE)arg;
    char buf[4096];
    DWORD got;
    while (ReadFile(h, buf, sizeof buf, &got, NULL) && got > 0) { /* discard */ }
    return 0;
}

static void pty_free(proc_ctx *ctx, pty_t *p) {
    pty_t **pp = &ctx->ptys;
    while (*pp) { if (*pp == p) { *pp = p->next; break; } pp = &(*pp)->next; }
    /* Kill the child, then tear the pseudo-console down the way the ConPTY docs
     * prescribe: DRAIN the output pipe on a thread WHILE ClosePseudoConsole runs,
     * so the console host's final flush never blocks on an unread pipe. (Closing
     * the read end first -- my earlier guess -- is exactly what deadlocked: the
     * host blocks writing its shutdown output to a dead pipe.) */
    if (p->job) wj_job_terminate(p->job, 1);
    HANDLE drain = (p->outR != NULL) ? CreateThread(NULL, 0, pty_drain_thread, p->outR, 0, NULL) : NULL;
    if (p->inW) { CloseHandle(p->inW); p->inW = NULL; }
    if (p->hpc) { ClosePseudoConsole(p->hpc); p->hpc = NULL; }
    if (drain) { WaitForSingleObject(drain, 5000); CloseHandle(drain); }
    if (p->outR) { CloseHandle(p->outR); p->outR = NULL; }
    if (p->proc) wj_proc_close(p->proc);
    if (p->job) wj_job_free(p->job);
    free(p);
}

static pty_t *pty_spawn(proc_ctx *ctx, run_opts *o, int cargc, const char **cargv,
                        int cols, int rows, const char **err) {
    char *exe = resolve_exe(cargv[0]);
    if (exe == NULL) { *err = "command not found on PATH"; return NULL; }
    char *cmdText = wj_make_cmdline(cargc, cargv);

    HANDLE   inR = NULL, inW = NULL, outR = NULL, outW = NULL;
    HPCON    hpc = NULL;
    wj_job  *job = NULL;
    LPPROC_THREAD_ATTRIBUTE_LIST al = NULL;
    int      alInited = 0;
    wchar_t *wApp = NULL, *wCmd = NULL, *wDir = NULL;
    pty_t   *result = NULL;

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(sa); sa.lpSecurityDescriptor = NULL; sa.bInheritHandle = FALSE;
    if (!CreatePipe(&inR, &inW, &sa, 0) || !CreatePipe(&outR, &outW, &sa, 0)) {
        *err = "CreatePipe failed"; goto done;
    }

    COORD size;
    size.X = (SHORT)cols; size.Y = (SHORT)rows;
    if (FAILED(CreatePseudoConsole(size, inR, outW, 0, &hpc))) {
        *err = "CreatePseudoConsole failed"; goto done;
    }
    /* the pseudoconsole owns its own refs to the child-side ends now */
    CloseHandle(inR);  inR = NULL;
    CloseHandle(outW); outW = NULL;

    job = wj_job_new(0, err);
    if (job == NULL) goto done;
    if (o->mem || o->cpu_100ns) {
        wj_limits lim = { 0 };
        lim.process_memory_bytes = o->mem; lim.process_cpu_100ns = o->cpu_100ns;
        if (wj_job_set_limits(job, &lim, err) != 0) goto done;
    }

    void *jobh[2];
    int njobs;
    if (ctx->in_root) { jobh[0] = wj_job_handle(job); njobs = 1; }
    else { jobh[0] = wj_job_handle(ctx->root); jobh[1] = wj_job_handle(job); njobs = 2; }

    SIZE_T alSize = 0;
    InitializeProcThreadAttributeList(NULL, 2, 0, &alSize);
    al = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(alSize);
    if (al == NULL || !InitializeProcThreadAttributeList(al, 2, 0, &alSize)) {
        *err = "InitializeProcThreadAttributeList failed"; goto done;
    }
    alInited = 1;
    if (!UpdateProcThreadAttribute(al, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                   jobh, (size_t)njobs * sizeof(HANDLE), NULL, NULL)) {
        *err = "UpdateProcThreadAttribute(JOB_LIST) failed"; goto done;
    }
    if (!UpdateProcThreadAttribute(al, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   hpc, sizeof(hpc), NULL, NULL)) {
        *err = "UpdateProcThreadAttribute(PSEUDOCONSOLE) failed"; goto done;
    }

    wApp = u8_to_u16(exe);
    wCmd = u8_to_u16(cmdText);
    if (o->dir && o->dir[0]) wDir = u8_to_u16(o->dir);
    if (wApp == NULL || wCmd == NULL) { *err = "bad exe or command line"; goto done; }

    STARTUPINFOEXW si;
    ZeroMemory(&si, sizeof si);
    si.StartupInfo.cb = sizeof si;
    si.lpAttributeList = al; /* ConPTY supplies stdio; no STARTF_USESTDHANDLES */

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof pi);
    if (!CreateProcessW(wApp, wCmd, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT,
                        NULL, wDir, &si.StartupInfo, &pi)) {
        static char e[128];
        snprintf(e, sizeof e, "CreateProcess failed (error %lu)", (unsigned long)GetLastError());
        *err = e; goto done;
    }
    CloseHandle(pi.hThread);

    result = (pty_t *)calloc(1, sizeof(*result));
    result->hpc = hpc; result->job = job; result->proc = pi.hProcess;
    result->pid = (int)pi.dwProcessId; result->inW = inW; result->outR = outR;
    snprintf(result->token, sizeof result->token, "pty#%d", ++ctx->pty_counter);
    result->next = ctx->ptys; ctx->ptys = result;
    hpc = NULL; job = NULL; inW = NULL; outR = NULL; /* ownership moved to result */

done:
    if (alInited) DeleteProcThreadAttributeList(al);
    free(al);
    free(wApp); free(wCmd); free(wDir);
    free(exe); free(cmdText);
    if (inR) CloseHandle(inR);
    if (outW) CloseHandle(outW);
    if (result == NULL) { /* failure: unwind what we made */
        if (inW) CloseHandle(inW);
        if (outR) CloseHandle(outR);
        if (hpc) ClosePseudoConsole(hpc);
        if (job) wj_job_free(job);
    }
    return result;
}

static int PtyCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    proc_ctx *ctx = (proc_ctx *)cd;
    static const char *const subs[] = { "spawn", "send", "read", "close", "list", NULL };
    enum { SPAWN, SEND, READ, CLOSE, LIST };
    int idx;
    if (objc < 2) { Tcl_WrongNumArgs(interp, 1, objv, "subcommand ?arg ...?"); return TCL_ERROR; }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", 0, &idx) != TCL_OK) return TCL_ERROR;

    if (idx == SPAWN) {
        run_opts o;
        if (parse_opts(interp, objc, objv, 2, &o) != TCL_OK) return TCL_ERROR;
        int cargc = 0;
        const char **cargv = build_argv(interp, objc, objv, o.cmd_index, &cargc);
        if (cargv == NULL) return run_error(interp, "usage", "pty spawn ?-opt val ...? ?--? command ?arg ...?");
        const char *err = NULL;
        pty_t *p = pty_spawn(ctx, &o, cargc, cargv, 80, 25, &err);
        free(cargv);
        if (p == NULL) return run_error(interp, "launch", err);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(p->token, -1));
        return TCL_OK;
    }
    if (idx == LIST) {
        Tcl_Obj *l = Tcl_NewListObj(0, NULL);
        for (pty_t *p = ctx->ptys; p; p = p->next) {
            Tcl_ListObjAppendElement(interp, l, Tcl_NewStringObj(p->token, -1));
        }
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }

    if (objc < 3) { Tcl_WrongNumArgs(interp, 2, objv, "token ?arg?"); return TCL_ERROR; }
    pty_t *p = pty_find(ctx, Tcl_GetString(objv[2]));
    if (p == NULL) return run_error(interp, "notfound", "no such pty");

    switch (idx) {
    case SEND: {
        if (objc != 4) { Tcl_WrongNumArgs(interp, 2, objv, "token text"); return TCL_ERROR; }
        Tcl_Size len;
        const char *s = Tcl_GetStringFromObj(objv[3], &len);
        DWORD written = 0;
        if (!WriteFile(p->inW, s, (DWORD)len, &written, NULL)) {
            return run_error(interp, "oserror", "write to pty failed");
        }
        return TCL_OK;
    }
    case READ: {
        int timeout_ms = 0;
        if (objc >= 5 && strcmp(Tcl_GetString(objv[3]), "-timeout") == 0) {
            long long t = parse_duration_ms(Tcl_GetString(objv[4]));
            if (t < 0) return run_error(interp, "badvalue", "bad -timeout value");
            timeout_ms = (int)t;
        }
        char buf[8192];
        ULONGLONG deadline = GetTickCount64() + (ULONGLONG)(timeout_ms > 0 ? timeout_ms : 0);
        for (;;) {
            DWORD avail = 0;
            if (!PeekNamedPipe(p->outR, NULL, 0, NULL, &avail, NULL)) {
                Tcl_SetObjResult(interp, Tcl_NewStringObj("", 0)); /* EOF: output ended */
                return TCL_OK;
            }
            if (avail > 0) {
                DWORD want = avail < sizeof(buf) ? avail : (DWORD)sizeof(buf);
                DWORD got = 0;
                if (!ReadFile(p->outR, buf, want, &got, NULL)) got = 0;
                Tcl_SetObjResult(interp, Tcl_NewStringObj(buf, (Tcl_Size)got));
                return TCL_OK;
            }
            if (GetTickCount64() >= deadline) break;
            Sleep(10);
        }
        Tcl_SetObjResult(interp, Tcl_NewStringObj("", 0));
        return TCL_OK;
    }
    case CLOSE:
        pty_free(ctx, p);
        return TCL_OK;
    }
    return TCL_OK;
}

/* ---- registration ------------------------------------------------------ */

/* Tear down any open pseudo-consoles at exit, so a REPL user who spawns a pty
 * and just quits doesn't leave a wedged console host behind. */
static void proc_atexit(void *cd) {
    proc_ctx *ctx = (proc_ctx *)cd;
    while (ctx->ptys) pty_free(ctx, ctx->ptys);
}

int Machteldproc_Init(Tcl_Interp *interp) {
    const char *err = NULL;
    wj_job *root = wj_job_new(1, &err); /* KILL_ON_JOB_CLOSE: nothing outlives machteld */
    if (root == NULL) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(err ? err : "root job creation failed", -1));
        return TCL_ERROR;
    }
    const char *ignore = NULL;
    int in_root = (wj_job_assign(root, (void *)GetCurrentProcess(), &ignore) == 0);
    /* Let detached daemons break away from root (so they outlive machteld).
     * Non-fatal: where the OS refuses, detach falls back to a normal launch. */
    (void)wj_job_allow_breakaway(root, &ignore);

    proc_ctx *ctx = (proc_ctx *)calloc(1, sizeof(*ctx));
    ctx->root = root;
    ctx->in_root = in_root;

    Tcl_Eval(interp, "namespace eval ::machteld {}");
    Tcl_CreateObjCommand(interp, "::machteld::run", RunCmd, ctx, NULL);
    Tcl_CreateObjCommand(interp, "::machteld::child", ChildCmd, ctx, NULL);
    Tcl_CreateObjCommand(interp, "::machteld::wait", WaitCmd, ctx, NULL);
    Tcl_CreateObjCommand(interp, "::machteld::detach", DetachCmd, ctx, NULL);
    Tcl_CreateObjCommand(interp, "::machteld::pty", PtyCmd, ctx, NULL);
    Tcl_CreateExitHandler(proc_atexit, ctx);
    Tcl_PkgProvide(interp, "machteld::proc", "0.1");
    return TCL_OK;
}
