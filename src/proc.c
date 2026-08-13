/*
 * proc.c -- machteld's process-control bridge over the winjob substrate.
 *
 * Machteldproc_Init establishes the host-owned root KILL_ON_JOB_CLOSE job for
 * every supervised launch and registers the execution-core verbs:
 *
 *   ::machteld::run   ?-timeout t -mem b -cpu t -dir d? ?--? cmd ?arg...?
 *       blocking one-shot -> dict {exit status out err pid truncated}
 *   ::machteld::child start|wait|kill|info|list|close ...
 *       async supervised children, addressed by an opaque token
 *   ::machteld::wait  ?-any? token ...
 *       block until all (or any) of the given children exit
 *
 * A child is launched born-in-job into the root and a per-command job (tree-kill
 * + limits); the host owns but never joins the root. stdout/stderr are captured
 * on drain threads (no pipe-buffer deadlock). `run` and `child start` share one
 * launch/reap core -- run just reaps immediately. Native failures use
 * -errorcode {MACHTELD <DOMAIN> <code>}; a nonzero child exit remains a normal
 * result.
 */
#include "winjob.h"
#include "machteld.h"

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
#include <wchar.h>
#include <limits.h>
#include <stdint.h>

/* ---- UTF-8 <-> UTF-16 -------------------------------------------------- */

static wchar_t *u8_to_u16(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (w == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w, n) <= 0) { free(w); return NULL; }
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
    const unsigned char *p = (const unsigned char *)s;
    if (*p < '0' || *p > '9') return -1;
    unsigned long long value = 0;
    while (*p >= '0' && *p <= '9') {
        unsigned digit = (unsigned)(*p++ - '0');
        if (value > (unsigned long long)LLONG_MAX / 10ULL ||
            (value == (unsigned long long)LLONG_MAX / 10ULL &&
             digit > (unsigned)((unsigned long long)LLONG_MAX % 10ULL))) return -1;
        value = value * 10ULL + digit;
    }
    unsigned long long mul;
    if (strcmp((const char *)p, "ms") == 0) mul = 1ULL;
    else if (strcmp((const char *)p, "s") == 0) mul = 1000ULL;
    else if (strcmp((const char *)p, "m") == 0) mul = 60000ULL;
    else if (strcmp((const char *)p, "h") == 0) mul = 3600000ULL;
    else return -1;
    if (value > (unsigned long long)LLONG_MAX / mul) return -1;
    return (long long)(value * mul);
}

static long long parse_bytes(const char *s) {
    const unsigned char *p = (const unsigned char *)s;
    if (*p < '0' || *p > '9') return -1;
    unsigned long long value = 0;
    while (*p >= '0' && *p <= '9') {
        unsigned digit = (unsigned)(*p++ - '0');
        if (value > (unsigned long long)LLONG_MAX / 10ULL ||
            (value == (unsigned long long)LLONG_MAX / 10ULL &&
             digit > (unsigned)((unsigned long long)LLONG_MAX % 10ULL))) return -1;
        value = value * 10ULL + digit;
    }
    unsigned long long mul = 1ULL;
    if (*p == 'K' || *p == 'k') { mul = 1ULL << 10; p++; }
    else if (*p == 'M' || *p == 'm') { mul = 1ULL << 20; p++; }
    else if (*p == 'G' || *p == 'g') { mul = 1ULL << 30; p++; }
    if (*p == 'B' || *p == 'b') p++;
    if (*p != '\0' || value > (unsigned long long)LLONG_MAX / mul) return -1;
    return (long long)(value * mul);
}

/* ---- deterministic program resolution --------------------------------- */

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

    /* A bare command name (no path separator) resolves from PATH ONLY -- not the
     * current directory -- so a cwd-local "cmd.exe" can't hijack a bare name. A
     * name containing a separator (absolute, or .\relative) is searched as given.
     * Extension-less names resolve against the executable extensions
     * (cmd -> cmd.exe); the bare name itself is never matched (it could hit a
     * non-executable in the search path). */
    int bare = (wcschr(wp, L'\\') == NULL && wcschr(wp, L'/') == NULL);
    wchar_t *pathEnv = NULL;
    if (bare) {
        DWORD need = GetEnvironmentVariableW(L"PATH", NULL, 0);
        if (need == 0) { free(wp); return NULL; }
        pathEnv = (wchar_t *)malloc((size_t)need * sizeof(wchar_t));
        if (pathEnv == NULL || GetEnvironmentVariableW(L"PATH", pathEnv, need) == 0) {
            free(pathEnv); free(wp); return NULL;
        }
    }

    wchar_t buf[MAX_PATH * 2];
    wchar_t *fpart = NULL;
    char *result = NULL;
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
        DWORD n = SearchPathW(bare ? pathEnv : NULL, wp, exts[e],
                              (DWORD)(sizeof(buf) / sizeof(buf[0])), buf, &fpart);
        if (n > 0 && n < sizeof(buf) / sizeof(buf[0])) {
            DWORD attr = GetFileAttributesW(buf);
            if (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY)) {
                result = u16_to_u8(buf);
                break;
            }
        }
    }
    free(pathEnv);
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
    DWORD  error;
} reader_t;

static DWORD WINAPI reader_thread(LPVOID arg) {
    reader_t *r = (reader_t *)arg;
    char tmp[8192];
    DWORD got = 0;
    for (;;) {
        if (!ReadFile(r->read, tmp, sizeof(tmp), &got, NULL)) {
            DWORD e = GetLastError();
            if (e != ERROR_BROKEN_PIPE && e != ERROR_PIPE_NOT_CONNECTED) r->error = e;
            break;
        }
        if (got == 0) break;
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

typedef struct {
    HANDLE write;
    char  *buf;
    size_t len;
    DWORD  error;
} writer_t;

static DWORD WINAPI writer_thread(LPVOID arg) {
    writer_t *w = (writer_t *)arg;
    size_t off = 0;
    while (off < w->len) {
        size_t left = w->len - off;
        DWORD want = left > (size_t)0x7ffff000u ? 0x7ffff000u : (DWORD)left;
        DWORD wrote = 0;
        if (!WriteFile(w->write, w->buf + off, want, &wrote, NULL) || wrote == 0) {
            w->error = GetLastError();
            break;
        }
        off += wrote;
    }
    CloseHandle(w->write);
    w->write = NULL;
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
    HANDLE          tIn;         /* finite -stdin writer */
    writer_t        wi;
    HANDLE          doneEv;      /* whole job exited and owned I/O drained */
    HANDLE          monitor;     /* enforces deadline without Tcl observation */
    int             stream;      /* callbacks pump output on interpreter thread */
    volatile LONG   monitor_failed;
    /* Channel names are stable lookup keys; scripts may close the corresponding
     * Tcl channels, so retaining Tcl_Channel pointers would be unsafe. */
    int             channels;    /* -channels was given */
    int             inherit;     /* -inherit: stdio is the parent's, not pipes */
    HANDLE          inherit_in, inherit_out, inherit_err;  /* BORROWED: ours, never closed here */
    HANDLE          inW;         /* stdin write end, kept open (channel mode) */
    char            chIn[24], chOut[24], chErr[24];
    ULONGLONG       deadline;    /* GetTickCount64() by which it must be done */
    int             reaped;      /* wait/reap already collected the exit + output */
    volatile LONG   killed;      /* was tree-killed by machteld (child kill) */
    volatile LONG   timeout;     /* specifically: killed because -timeout elapsed */
    long long       exit_code;
    struct child_s *next;        /* registry chain */
} child_t;

/* Client data shared by the verbs: the root job and live resource registries.
 * The supervisor owns the root job but is deliberately not a member: closing a
 * KILL_ON_JOB_CLOSE job containing the host would replace its intended process
 * exit status with the kernel's job-termination status. */
typedef struct {
    wj_job  *root;
    child_t *children;    /* singly-linked list of tracked children */
    int      counter;     /* child token sequence */
    struct pty_s *ptys;   /* singly-linked list of open ptys */
    int      pty_counter; /* pty token sequence */
    struct watch_s *watches; /* singly-linked list of open directory watches */
    int      watch_counter;  /* watch token sequence */
} proc_ctx;

/* `wait` multiplexes over EVERY handle kind, not just children, so it resolves a
 * token through this seam instead of reaching into child_t. A waitable is: the
 * OS handle to block on, and whether the token is already satisfied and needs no
 * wait at all. What "ready" means is the handle kind's business -- a child is
 * ready when it has exited, a watch when it has events pending -- and `wait`
 * does not need to know which. Defined here, ahead of WaitCmd; the watch half is
 * implemented further down with the rest of that verb. */
typedef struct {
    const char *token;
    HANDLE      h;
    int         ready;    /* already satisfied: do not wait on it */
} waitable;

static int watch_waitable(proc_ctx *ctx, const char *token, waitable *w);

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
    const char        *stdin_text; /* NULL => child stdin is the null device */
    Tcl_Size           stdin_len;
    Tcl_Obj           *env_obj;    /* the -env {K V ...} list, or NULL to inherit */
    void              *env_block;  /* built UTF-16 env block (borrowed; the command owns the buffer) */
    Tcl_Obj           *onout;      /* -onout prefix: each stdout line appended + evaluated (run only) */
    Tcl_Obj           *onerr;      /* -onerr prefix: each stderr line appended + evaluated (run only) */
    int                channels;   /* -channels: hand the pipes over as Tcl channels */
    int                inherit;    /* -inherit: the child gets OUR stdio, not pipes */
    const char        *arg0;       /* -arg0: what the child reads as argv[0], if not its own path */
    int                cmd_index;  /* objv index where the command begins */
} run_opts;

enum {
    OPT_TIMEOUT  = 1u << 0,
    OPT_MEM      = 1u << 1,
    OPT_CPU      = 1u << 2,
    OPT_DIR      = 1u << 3,
    OPT_ARG0     = 1u << 4,
    OPT_STDIN    = 1u << 5,
    OPT_ENV      = 1u << 6,
    OPT_ONOUT    = 1u << 7,
    OPT_ONERR    = 1u << 8,
    OPT_CHANNELS = 1u << 9,
    OPT_INHERIT  = 1u << 10
};

/* The domain names the public command, not the internal helper. */
static int mt_error(Tcl_Interp *interp, const char *domain, const char *code, const char *msg) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg ? msg : "command failed", -1));
    Tcl_SetErrorCode(interp, "MACHTELD", domain, code, (char *)NULL);
    return TCL_ERROR;
}

/* Build a UTF-16 environment block into buf (cap wchars): the inherited
 * environment with the given key/value overrides applied (case-insensitive key;
 * the override wins). pairs is a Tcl list {K V K V ...}. Returns 0 (buf holds a
 * double-NUL-terminated block) or -1 and sets *err on bad input / overflow. buf
 * is the caller's (stack) buffer -- valid only for that frame, which suffices
 * because CreateProcess copies the block into the child at launch. */
static const char *obj_no_nul(Tcl_Obj *obj, Tcl_Size *len) {
    const char *s = Tcl_GetStringFromObj(obj, len);
    return memchr(s, '\0', (size_t)*len) == NULL ? s : NULL;
}

typedef struct {
    const wchar_t *text;
    size_t text_len;
    size_t name_len;
    wchar_t *owned;
} env_item;

/* Ordinary entries are NAME=VALUE. Windows' per-drive current-directory
 * entries are exceptional: =C:=C:\path has the name =C:, so its separator is
 * the second '='. They must be copied and sorted with the ordinary entries. */
static size_t env_name_len(const wchar_t *entry) {
    size_t n = entry[0] == L'=' ? 1 : 0;
    while (entry[n] != L'\0' && entry[n] != L'=') n++;
    return n;
}

/* Windows requires environment names in case-insensitive Unicode ordinal
 * order, without locale influence. A zero return is an API failure; otherwise
 * the result is one of CSTR_LESS_THAN, CSTR_EQUAL, CSTR_GREATER_THAN. */
static int env_name_compare(const wchar_t *a, size_t na,
                            const wchar_t *b, size_t nb) {
    if (na > INT_MAX || nb > INT_MAX) return 0;
    return CompareStringOrdinal(a, (int)na, b, (int)nb, TRUE);
}

static int build_env_block(Tcl_Interp *interp, Tcl_Obj *pairs, wchar_t *buf, size_t cap, const char **err) {
    Tcl_Size np;
    Tcl_Obj **pv;
    if (Tcl_ListObjGetElements(interp, pairs, &np, &pv) != TCL_OK) { *err = "bad -env value"; return -1; }
    if (np % 2 != 0) { *err = "-env needs key/value pairs"; return -1; }
    if (np / 2 > INT_MAX) { *err = "environment too large"; return -1; }
    int nover = (int)(np / 2);

    wchar_t **okey = (wchar_t **)calloc((size_t)(nover ? nover : 1), sizeof(wchar_t *));
    size_t *okey_len = (size_t *)calloc((size_t)(nover ? nover : 1), sizeof(size_t));
    if (okey == NULL || okey_len == NULL) {
        free(okey);
        free(okey_len);
        *err = "out of memory";
        return -1;
    }
    int rc = 0;
    const char *e2 = NULL;
    for (int j = 0; j < nover; j++) {
        Tcl_Size nk = 0;
        const char *key = obj_no_nul(pv[2 * j], &nk);
        if (key == NULL || nk == 0 || memchr(key, '=', (size_t)nk) != NULL) {
            rc = -1;
            e2 = "environment keys must be nonempty and contain neither NUL nor '='";
            break;
        }
        okey[j] = u8_to_u16(key);
        if (okey[j] == NULL) { rc = -1; e2 = "bad -env entry"; break; }
        okey_len[j] = wcslen(okey[j]);
        for (int k = 0; k < j; k++) {
            int comparison = env_name_compare(okey[k], okey_len[k], okey[j], okey_len[j]);
            if (comparison == 0) {
                rc = -1;
                e2 = "cannot compare environment keys";
                break;
            }
            if (comparison == CSTR_EQUAL) {
                rc = -1;
                e2 = "duplicate environment key";
                break;
            }
        }
        if (rc != 0) break;
    }

    LPWCH env = NULL;
    env_item *items = NULL;
    size_t nitems = 0;
    size_t pos = 0;

    /* Collect inherited entries, including =X: drive-current-directory state,
     * but skip an ordinary entry when a caller override names it. Keep pointers
     * into the inherited block until the sorted block has been emitted. */
    env = rc == 0 ? GetEnvironmentStringsW() : NULL;
    if (rc == 0 && env == NULL) { rc = -1; e2 = "cannot read inherited environment"; }
    size_t inherited_count = 0;
    for (wchar_t *e = env; e != NULL && *e; e += wcslen(e) + 1) inherited_count++;
    if (rc == 0 && inherited_count > SIZE_MAX - (size_t)nover) {
        rc = -1;
        e2 = "environment too large";
    }
    if (rc == 0) {
        size_t capacity = inherited_count + (size_t)nover;
        items = (env_item *)calloc(capacity ? capacity : 1, sizeof(*items));
        if (items == NULL) { rc = -1; e2 = "out of memory"; }
    }
    for (wchar_t *e = env; e != NULL && *e && rc == 0; ) {
        size_t elen = wcslen(e);
        size_t klen = env_name_len(e);
        int overridden = 0;
        for (int j = 0; j < nover; j++) {
            int comparison = env_name_compare(e, klen, okey[j], okey_len[j]);
            if (comparison == 0) {
                rc = -1;
                e2 = "cannot compare environment keys";
                break;
            }
            if (comparison == CSTR_EQUAL) { overridden = 1; break; }
        }
        if (rc == 0 && !overridden) {
            items[nitems].text = e;
            items[nitems].text_len = elen;
            items[nitems].name_len = klen;
            nitems++;
        }
        e += elen + 1;
    }

    /* Materialize caller overrides as ordinary NAME=VALUE entries. Keys were
     * already validated and de-duplicated case-insensitively above. */
    for (int j = 0; j < nover && rc == 0; j++) {
        Tcl_Size nv = 0;
        const char *value = obj_no_nul(pv[2 * j + 1], &nv);
        wchar_t *wv = value ? u8_to_u16(value) : NULL;
        size_t lk = okey_len[j], lv = wv ? wcslen(wv) : 0;
        if (value == NULL) { rc = -1; e2 = "environment values may not contain NUL"; }
        else if (okey[j] == NULL || wv == NULL) { rc = -1; e2 = "bad -env entry"; }
        else if (lk >= cap || lv >= cap || lk + lv + 2 > cap) {
            rc = -1;
            e2 = "environment too large";
        }
        else {
            size_t entry_len = lk + 1 + lv;
            wchar_t *entry = (wchar_t *)malloc((entry_len + 1) * sizeof(wchar_t));
            if (entry == NULL) {
                rc = -1;
                e2 = "out of memory";
            } else {
                memcpy(entry, okey[j], lk * sizeof(wchar_t));
                entry[lk] = L'=';
                memcpy(entry + lk + 1, wv, lv * sizeof(wchar_t));
                entry[entry_len] = L'\0';
                items[nitems].text = entry;
                items[nitems].text_len = entry_len;
                items[nitems].name_len = lk;
                items[nitems].owned = entry;
                nitems++;
            }
        }
        free(wv);
    }

    /* Stable insertion sort is ample for a block capped at 32K characters and
     * lets CompareStringOrdinal failures remain reportable. Case-insensitive
     * equal names retain their inherited order. */
    for (size_t i = 1; i < nitems && rc == 0; i++) {
        env_item item = items[i];
        size_t j = i;
        while (j > 0) {
            int comparison = env_name_compare(items[j - 1].text, items[j - 1].name_len,
                                              item.text, item.name_len);
            if (comparison == 0) {
                rc = -1;
                e2 = "cannot sort environment";
                break;
            }
            if (comparison != CSTR_GREATER_THAN) break;
            items[j] = items[j - 1];
            j--;
        }
        items[j] = item;
    }

    for (size_t i = 0; i < nitems && rc == 0; i++) {
        if (pos >= cap || items[i].text_len > cap - pos - 1) {
            rc = -1;
            e2 = "environment too large";
            break;
        }
        memcpy(buf + pos, items[i].text, items[i].text_len * sizeof(wchar_t));
        pos += items[i].text_len;
        buf[pos++] = L'\0';
    }
    if (rc == 0) {
        size_t closing_nuls = nitems == 0 ? 2 : 1;
        if (closing_nuls > cap - pos) { rc = -1; e2 = "environment too large"; }
        else while (closing_nuls-- > 0) buf[pos++] = L'\0';
    }

    for (size_t i = 0; i < nitems; i++) free(items[i].owned);
    free(items);
    if (env != NULL) FreeEnvironmentStringsW(env);
    for (int j = 0; j < nover; j++) free(okey[j]);
    free(okey);
    free(okey_len);
    if (rc != 0) *err = e2;
    return rc;
}

static int parse_opts(Tcl_Interp *interp, const char *dom, int objc,
                      Tcl_Obj *const objv[], int i0, unsigned allowed, run_opts *o) {
    o->timeout_ms = -1;
    o->mem = 0;
    o->cpu_100ns = 0;
    o->dir = NULL;
    o->stdin_text = NULL;
    o->stdin_len = 0;
    o->env_obj = NULL;
    o->env_block = NULL;
    o->onout = NULL;
    o->onerr = NULL;
    o->channels = 0;
    /* Initialize every field because this structure lives on the stack. */
    o->inherit = 0;
    o->arg0 = NULL;
    int i = i0;
    for (; i < objc; i++) {
        Tcl_Size alen = 0;
        const char *a = obj_no_nul(objv[i], &alen);
        if (a == NULL) return mt_error(interp, dom, "badvalue", "option name may not contain NUL");
        if (strcmp(a, "--") == 0) { i++; break; }
        if (a[0] != '-' || a[1] == '\0') break;
        if (strcmp(a, "-channels") == 0) {
            if (!(allowed & OPT_CHANNELS)) return mt_error(interp, dom, "usage", "option is not supported by this command");
            o->channels = 1;
            continue;
        }
        if (strcmp(a, "-inherit") == 0) {
            if (!(allowed & OPT_INHERIT)) return mt_error(interp, dom, "usage", "option is not supported by this command");
            o->inherit = 1;
            continue;
        }
        if (i + 1 >= objc) return mt_error(interp, dom, "usage", "option needs a value");
        Tcl_Size vlen = 0;
        const char *v = Tcl_GetStringFromObj(objv[i + 1], &vlen);
        int has_nul = memchr(v, '\0', (size_t)vlen) != NULL;
        if (strcmp(a, "-timeout") == 0) {
            if (!(allowed & OPT_TIMEOUT)) return mt_error(interp, dom, "usage", "option is not supported by this command");
            if (has_nul) return mt_error(interp, dom, "badvalue", "duration may not contain NUL");
            o->timeout_ms = parse_duration_ms(v);
            if (o->timeout_ms < 0 || (unsigned long long)o->timeout_ms >= WJ_INFINITE)
                return mt_error(interp, dom, "badvalue", "bad -timeout value");
        } else if (strcmp(a, "-mem") == 0) {
            if (!(allowed & OPT_MEM)) return mt_error(interp, dom, "usage", "option is not supported by this command");
            if (has_nul) return mt_error(interp, dom, "badvalue", "byte size may not contain NUL");
            long long b = parse_bytes(v);
            if (b < 0) return mt_error(interp, dom, "badvalue", "bad -mem value");
            o->mem = (unsigned long long)b;
        } else if (strcmp(a, "-cpu") == 0) {
            if (!(allowed & OPT_CPU)) return mt_error(interp, dom, "usage", "option is not supported by this command");
            if (has_nul) return mt_error(interp, dom, "badvalue", "duration may not contain NUL");
            long long d = parse_duration_ms(v);
            if (d < 0 || (unsigned long long)d > (unsigned long long)LLONG_MAX / 10000ULL)
                return mt_error(interp, dom, "badvalue", "bad -cpu value");
            o->cpu_100ns = (unsigned long long)d * 10000ULL;
        } else if (strcmp(a, "-dir") == 0) {
            if (!(allowed & OPT_DIR)) return mt_error(interp, dom, "usage", "option is not supported by this command");
            if (has_nul) return mt_error(interp, dom, "badvalue", "working directory may not contain NUL");
            o->dir = v;
        } else if (strcmp(a, "-arg0") == 0) {
            if (!(allowed & OPT_ARG0)) return mt_error(interp, dom, "usage", "option is not supported by this command");
            if (has_nul) return mt_error(interp, dom, "badvalue", "-arg0 may not contain NUL");
            /* Resolution uses the command name; -arg0 only changes argv[0]. */
            o->arg0 = v;
        } else if (strcmp(a, "-stdin") == 0) {
            if (!(allowed & OPT_STDIN)) return mt_error(interp, dom, "usage", "option is not supported by this command");
            o->stdin_text = v;
            o->stdin_len = vlen;
        } else if (strcmp(a, "-env") == 0) {
            if (!(allowed & OPT_ENV)) return mt_error(interp, dom, "usage", "option is not supported by this command");
            o->env_obj = objv[i + 1];
        } else if (strcmp(a, "-onout") == 0) {
            if (!(allowed & OPT_ONOUT)) return mt_error(interp, dom, "usage", "option is not supported by this command");
            o->onout = objv[i + 1];
        } else if (strcmp(a, "-onerr") == 0) {
            if (!(allowed & OPT_ONERR)) return mt_error(interp, dom, "usage", "option is not supported by this command");
            o->onerr = objv[i + 1];
        } else {
            return mt_error(interp, dom, "usage", "unknown option");
        }
        i++;
    }
    o->cmd_index = i;
    return TCL_OK;
}

/* ---- launch / reap / dict / free (shared core) ------------------------- */

/* Launch cargv born-in-job with captured stdout/stderr. On success returns the
 * child (reader threads running unless `stream`, not yet reaped); on failure
 * returns NULL and sets *err. `track` registers it under a token; otherwise it
 * is a transient run. `stream` suppresses the reader threads so the caller can
 * pump the pipes itself (run -onout/-onerr).
 *
 * *code distinguishes resolution (`notfound`) from later launch failures. */
/* Apply -arg0 only after executable resolution. */
static const char **argv_with_arg0(run_opts *o, int cargc, const char **cargv,
                                   const char **err) {
    if (o->arg0 == NULL) return cargv;
    const char **a = (const char **)malloc(sizeof(*a) * (size_t)cargc);
    if (a == NULL) { *err = "out of memory"; return NULL; }
    a[0] = o->arg0;
    for (int i = 1; i < cargc; i++) a[i] = cargv[i];
    return a;
}

static int handle_signaled(HANDLE h) {
    if (h == NULL) return 1;
    return WaitForSingleObject(h, 0) == WAIT_OBJECT_0;
}

/* A child is complete only when its entire job is empty. The direct process can
 * exit first while a descendant remains alive and holds capture pipes open.
 * This monitor also owns the start-time deadline, so expiry does not depend on
 * a later Tcl command observing the child. */
static DWORD WINAPI child_monitor_thread(LPVOID arg) {
    child_t *c = (child_t *)arg;
    int direct_done = 0;
    int query_failed = 0;
    for (;;) {
        if (!direct_done) {
            DWORD wr = WaitForSingleObject((HANDLE)c->proc, 0);
            if (wr == WAIT_OBJECT_0) {
                DWORD code = 0;
                if (GetExitCodeProcess((HANDLE)c->proc, &code)) {
                    c->exit_code = (long long)(unsigned long long)code;
                    direct_done = 1;
                } else {
                    InterlockedExchange(&c->monitor_failed, 1);
                    query_failed = 1;
                }
            } else if (wr == WAIT_FAILED) {
                InterlockedExchange(&c->monitor_failed, 1);
                query_failed = 1;
                direct_done = 1;
                InterlockedExchange(&c->killed, 1);
                if (wj_job_terminate(c->job, 1) != 0) wj_job_close(c->job);
            }
        }

        unsigned active = 0;
        const char *ignore = NULL;
        if (!query_failed && wj_job_active(c->job, &active, &ignore) != 0) {
            InterlockedExchange(&c->monitor_failed, 1);
            query_failed = 1;
            InterlockedExchange(&c->killed, 1);
            if (wj_job_terminate(c->job, 1) != 0) wj_job_close(c->job);
        }

        int io_done = handle_signaled(c->tIn);
        if (!c->stream && !c->channels && !c->inherit) {
            io_done = io_done && handle_signaled(c->tOut) && handle_signaled(c->tErr);
        }
        if (direct_done && io_done && (query_failed || active == 0)) break;
        ULONGLONG now = GetTickCount64();
        if (c->deadline != 0 && now >= c->deadline) {
            InterlockedExchange(&c->timeout, 1);
            InterlockedExchange(&c->killed, 1);
            if (wj_job_terminate(c->job, 1) != 0) {
                InterlockedExchange(&c->monitor_failed, 1);
                query_failed = 1;
                wj_job_close(c->job); /* KILL_ON_JOB_CLOSE fallback */
            }
            c->deadline = 0;
        }
        Sleep(5);
    }
    SetEvent(c->doneEv);
    return 0;
}

static child_t *child_launch(proc_ctx *ctx, run_opts *o, int cargc, const char **cargv,
                             int track, int stream, const char **err, const char **code) {
    char *exe = resolve_exe(cargv[0]);
    if (exe == NULL) { *err = "command not found on PATH"; *code = "notfound"; return NULL; }

    child_t *c = (child_t *)calloc(1, sizeof(*c));
    if (c == NULL) { free(exe); *err = "out of memory"; return NULL; }
    HANDLE outW = NULL, errW = NULL, nul = NULL, stdinR = NULL, stdinW = NULL;
    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = FALSE;

    /* INHERIT MODE: the child gets OUR stdio, so it writes to the terminal the
     * user is looking at -- colours, progress bars, a pager, Ctrl-C. Nothing is
     * captured and nothing is read, because there is no pipe in between.
     *
     * This needs no change in the launcher: `wj_launch` duplicates whichever
     * handles it is given into inheritable copies and restricts inheritance to
     * exactly those, so handing it the parent's console handles gives the child
     * the console with every supervision guarantee intact -- born into the root
     * and per-command jobs, tree-killable, capped, deadline enforced.
     *
     * A handle can legitimately be absent (a GUI process has no console), and a
     * NULL handle cannot be duplicated, so each stream falls back to NUL
     * independently rather than the whole launch failing. */
    if (o->inherit) {
        HANDLE si = GetStdHandle(STD_INPUT_HANDLE);
        HANDLE so = GetStdHandle(STD_OUTPUT_HANDLE);
        HANDLE se = GetStdHandle(STD_ERROR_HANDLE);
        if (si == INVALID_HANDLE_VALUE) si = NULL;
        if (so == INVALID_HANDLE_VALUE) so = NULL;
        if (se == INVALID_HANDLE_VALUE) se = NULL;
        if (si == NULL || so == NULL || se == NULL) {
            nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
            if (nul == INVALID_HANDLE_VALUE) { nul = NULL; *err = "open NUL failed"; goto fail; }
        }
        c->inherit_in  = (si != NULL) ? si : nul;
        c->inherit_out = (so != NULL) ? so : nul;
        c->inherit_err = (se != NULL) ? se : nul;
    } else {
        if (!CreatePipe(&c->outR, &outW, &sa, 0) || !CreatePipe(&c->errR, &errW, &sa, 0)) {
            *err = "CreatePipe failed";
            goto fail;
        }
        if (o->stdin_text != NULL || o->channels) {
            if (!CreatePipe(&stdinR, &stdinW, &sa, 0)) { *err = "CreatePipe(stdin) failed"; goto fail; }
        } else {
            nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              NULL, OPEN_EXISTING, 0, NULL);
            if (nul == INVALID_HANDLE_VALUE) { nul = NULL; *err = "open NUL failed"; goto fail; }
        }
    }

    c->job = wj_job_new(1, err);
    if (c->job == NULL) goto fail;
    if (o->mem || o->cpu_100ns) {
        wj_limits lim = { 0 };
        lim.process_memory_bytes = o->mem;
        lim.process_cpu_100ns = o->cpu_100ns;
        if (wj_job_set_limits(c->job, &lim, err) != 0) goto fail;
    }

    /* Root first, then the narrower per-command job, is the required nesting
     * order for PROC_THREAD_ATTRIBUTE_JOB_LIST. */
    void *jobh[2];
    jobh[0] = wj_job_handle(ctx->root);
    jobh[1] = wj_job_handle(c->job);
    int njobs = 2;
    wj_stdio io;
    if (o->inherit) {
        io = (wj_stdio){ c->inherit_in, c->inherit_out, c->inherit_err };
    } else {
        io = (wj_stdio){ (o->stdin_text != NULL || o->channels) ? stdinR : nul, outW, errW };
    }
    c->inherit = o->inherit;
    c->channels = o->channels;
    c->stream = stream;
    const char **largv = argv_with_arg0(o, cargc, cargv, err);
    if (largv == NULL) goto fail;
    int lrc = wj_launch(exe, cargc, largv, o->dir, jobh, njobs, &io, 0, o->env_block, &c->pid, &c->proc, err);
    if (largv != cargv) free((void *)largv);
    if (lrc != 0) goto fail;
    if (o->timeout_ms >= 0) c->deadline = GetTickCount64() + (ULONGLONG)o->timeout_ms;

    if (outW) { CloseHandle(outW); outW = NULL; }
    if (errW) { CloseHandle(errW); errW = NULL; }
    if (nul) { CloseHandle(nul); nul = NULL; }
    if (stdinR) { CloseHandle(stdinR); stdinR = NULL; }

    /* Start output drains before feeding stdin. A child that writes enough
     * output before reading its input would otherwise deadlock two full pipes. */
    if (!o->channels && !o->inherit) {
        size_t cap = 1u << 20;
        c->ro.read = c->outR; c->ro.cap = cap; c->ro.buf = (char *)malloc(cap);
        c->re.read = c->errR; c->re.cap = cap; c->re.buf = (char *)malloc(cap);
        if (c->ro.buf == NULL || c->re.buf == NULL) { *err = "out of memory"; goto fail; }
        if (!stream) {
            c->tOut = CreateThread(NULL, 0, reader_thread, &c->ro, 0, NULL);
            if (c->tOut == NULL) { *err = "cannot start stdout reader thread"; goto fail; }
            c->tErr = CreateThread(NULL, 0, reader_thread, &c->re, 0, NULL);
            if (c->tErr == NULL) { *err = "cannot start stderr reader thread"; goto fail; }
        }
    }

    if (o->channels) {
        c->inW = stdinW; stdinW = NULL;
    } else if (o->stdin_text != NULL) {
        if (o->stdin_len > 0) {
            c->wi.buf = (char *)malloc((size_t)o->stdin_len);
            if (c->wi.buf == NULL) { *err = "out of memory"; goto fail; }
            memcpy(c->wi.buf, o->stdin_text, (size_t)o->stdin_len);
            c->wi.len = (size_t)o->stdin_len;
            c->wi.write = stdinW; stdinW = NULL;
            c->tIn = CreateThread(NULL, 0, writer_thread, &c->wi, 0, NULL);
            if (c->tIn == NULL) { *err = "cannot start stdin writer thread"; goto fail; }
        } else {
            CloseHandle(stdinW); stdinW = NULL;
        }
    }

    c->doneEv = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (c->doneEv == NULL) { *err = "cannot create child completion event"; goto fail; }
    c->monitor = CreateThread(NULL, 0, child_monitor_thread, c, 0, NULL);
    if (c->monitor == NULL) { *err = "cannot start child monitor thread"; goto fail; }

    free(exe);
    if (track) {
        snprintf(c->token, sizeof c->token, "child#%d", ++ctx->counter);
        c->next = ctx->children;
        ctx->children = c;
    }
    return c;

fail:
    if (c->proc && c->job) (void)wj_job_terminate(c->job, 1);
    if (outW) CloseHandle(outW);
    if (errW) CloseHandle(errW);
    if (nul) CloseHandle(nul);
    if (stdinR) CloseHandle(stdinR);
    if (stdinW) CloseHandle(stdinW);
    if (c->inW) CloseHandle(c->inW);
    if (c->wi.write && c->tIn == NULL) { CloseHandle(c->wi.write); c->wi.write = NULL; }
    if (c->tIn) { WaitForSingleObject(c->tIn, INFINITE); CloseHandle(c->tIn); }
    if (c->tOut) { WaitForSingleObject(c->tOut, INFINITE); CloseHandle(c->tOut); }
    if (c->tErr) { WaitForSingleObject(c->tErr, INFINITE); CloseHandle(c->tErr); }
    if (c->monitor) { WaitForSingleObject(c->monitor, INFINITE); CloseHandle(c->monitor); }
    if (c->proc) wj_proc_close(c->proc);
    if (c->doneEv) CloseHandle(c->doneEv);
    if (c->outR) CloseHandle(c->outR);
    if (c->errR) CloseHandle(c->errR);
    if (c->job) wj_job_free(c->job);
    free(c->wi.buf);
    free(c->ro.buf);
    free(c->re.buf);
    free(exe);
    free(c);
    return NULL;
}

/* Hand a child's pipes to Tcl as channels, and record their NAMES.
 *
 * THE DOUBLE-CLOSE THIS AVOIDS: Tcl_MakeFileChannel takes ownership of the OS
 * handle, so closing the channel closes the handle. child_reap closes outR/errR
 * unconditionally, and wj teardown would close them again -- on Windows a
 * double CloseHandle is not an error you catch, it is a process that stops. So
 * the handles are nulled here the moment Tcl owns them, and every later cleanup
 * path skips what it no longer holds.
 *
 * Registered in the interp so a script can `close` them itself; cleanup looks
 * the names up again rather than keeping pointers, because a name that no longer
 * resolves is a fact while a stale pointer is a crash. */
static int child_channels(Tcl_Interp *interp, child_t *c) {
    Tcl_Channel ci = Tcl_MakeFileChannel((void *)c->inW,  TCL_WRITABLE);
    if (ci == NULL) return -1;
    c->inW = NULL;
    Tcl_RegisterChannel(interp, ci);
    snprintf(c->chIn, sizeof c->chIn, "%s", Tcl_GetChannelName(ci));

    Tcl_Channel co = Tcl_MakeFileChannel((void *)c->outR, TCL_READABLE);
    if (co == NULL) { Tcl_UnregisterChannel(interp, ci); c->chIn[0] = '\0'; return -1; }
    c->outR = NULL;
    Tcl_RegisterChannel(interp, co);
    snprintf(c->chOut, sizeof c->chOut, "%s", Tcl_GetChannelName(co));

    Tcl_Channel ce = Tcl_MakeFileChannel((void *)c->errR, TCL_READABLE);
    if (ce == NULL) {
        Tcl_UnregisterChannel(interp, ci);
        Tcl_UnregisterChannel(interp, co);
        c->chIn[0] = c->chOut[0] = '\0';
        return -1;
    }
    c->errR = NULL;
    Tcl_RegisterChannel(interp, ce);
    snprintf(c->chErr, sizeof c->chErr, "%s", Tcl_GetChannelName(ce));
    /* Tcl 9 folds byte-oriented encoding into `-translation binary`; its old
     * `-encoding binary` spelling is explicitly unsupported. Line buffering on
     * stdin preserves the worker protocol default; callers can change it. */
    if (Tcl_SetChannelOption(interp, ci, "-translation", "binary") != TCL_OK ||
        Tcl_SetChannelOption(interp, co, "-translation", "binary") != TCL_OK ||
        Tcl_SetChannelOption(interp, ce, "-translation", "binary") != TCL_OK ||
        Tcl_SetChannelOption(interp, ci, "-buffering", "line") != TCL_OK) {
        Tcl_UnregisterChannel(interp, ci);
        Tcl_UnregisterChannel(interp, co);
        Tcl_UnregisterChannel(interp, ce);
        c->chIn[0] = c->chOut[0] = c->chErr[0] = '\0';
        return -1;
    }
    return 0;
}

/* Close whatever the script has not already closed. */
static void child_channels_free(Tcl_Interp *interp, child_t *c) {
    if (!c->channels) return;
    const char *names[3] = { c->chIn, c->chOut, c->chErr };
    for (int k = 0; k < 3; k++) {
        if (names[k][0] == '\0') continue;
        Tcl_Channel ch = Tcl_GetChannel(interp, names[k], NULL);
        if (ch != NULL) Tcl_UnregisterChannel(interp, ch);
    }
    c->chIn[0] = c->chOut[0] = c->chErr[0] = '\0';
}

/* Wait for whole-job completion, then join and close all owned I/O. */
static int child_reap(child_t *c, unsigned wait_ms, const char **err) {
    if (c->reaped) return 0;
    DWORD w = WaitForSingleObject(c->doneEv, wait_ms);
    if (w == WAIT_TIMEOUT) return 1;
    if (w != WAIT_OBJECT_0) { *err = "waiting for child completion failed"; return -1; }
    HANDLE threads[4] = { c->monitor, c->tIn, c->tOut, c->tErr };
    int join_failed = 0;
    for (int i = 0; i < 4; i++) {
        if (threads[i] == NULL) continue;
        if (WaitForSingleObject(threads[i], INFINITE) != WAIT_OBJECT_0) {
            join_failed = 1;
        }
        CloseHandle(threads[i]);
    }
    c->monitor = c->tIn = c->tOut = c->tErr = NULL;
    const char *io_error = NULL;
    if (join_failed) io_error = "joining child I/O thread failed";
    else if (c->monitor_failed) io_error = "child monitor failed";
    else if (c->ro.error || c->re.error) io_error = "reading child output failed";
    else if (c->wi.error && !c->killed) io_error = "writing child input failed";
    if (c->proc) { wj_proc_close(c->proc); c->proc = NULL; }
    if (c->outR) { CloseHandle(c->outR); c->outR = NULL; }
    if (c->errR) { CloseHandle(c->errR); c->errR = NULL; }
    if (c->doneEv) { CloseHandle(c->doneEv); c->doneEv = NULL; }
    c->reaped = 1;
    if (io_error != NULL) { *err = io_error; return -1; }
    return 0;
}

/* The one result shape, shared by `run` and `child wait`. `alive` says the child
 * is STILL RUNNING -- only `child wait` can produce that, when the caller's own
 * -timeout bound expired without the child finishing. The shape does not fork
 * for it: same keys, `exit` empty because there is no exit code yet, and
 * `status running` so a caller can tell "not done" from "done, and here is how".
 * A forked shape would have been the cheaper change and the wrong one. */
static Tcl_Obj *child_dict_ex(Tcl_Interp *interp, child_t *c, int alive) {
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("exit", -1),
                   alive ? Tcl_NewStringObj("", -1) : Tcl_NewWideIntObj((Tcl_WideInt)c->exit_code));
    const char *st = alive ? "running"
                   : c->timeout ? "timeout" : c->killed ? "killed" : (c->exit_code == 0 ? "ok" : "error");
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("status", -1), Tcl_NewStringObj(st, -1));
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("out", -1),
                   Tcl_NewByteArrayObj((const unsigned char *)(c->ro.buf ? c->ro.buf : ""),
                                       (Tcl_Size)c->ro.len));
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("err", -1),
                   Tcl_NewByteArrayObj((const unsigned char *)(c->re.buf ? c->re.buf : ""),
                                       (Tcl_Size)c->re.len));
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("pid", -1), Tcl_NewIntObj(c->pid));
    Tcl_Obj *trunc = Tcl_NewListObj(0, NULL);
    if (c->ro.truncated) Tcl_ListObjAppendElement(interp, trunc, Tcl_NewStringObj("out", -1));
    if (c->re.truncated) Tcl_ListObjAppendElement(interp, trunc, Tcl_NewStringObj("err", -1));
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("truncated", -1), trunc);
    return d;
}

static Tcl_Obj *child_dict(Tcl_Interp *interp, child_t *c) {
    return child_dict_ex(interp, c, 0);
}

static void child_free(child_t *c) {
    if (c == NULL) return;
    if (!c->reaped) {
        if (c->job && wj_job_terminate(c->job, 1) != 0) wj_job_close(c->job);
        const char *e = NULL;
        if (child_reap(c, WJ_INFINITE, &e) != 0 && !c->reaped) {
            /* A live monitor or I/O thread still owns c. Leak on this exceptional
             * cleanup path rather than freeing memory another thread may touch. */
            return;
        }
    }
    free(c->ro.buf);
    free(c->re.buf);
    free(c->wi.buf);
    if (c->doneEv) CloseHandle(c->doneEv);
    if (c->job) wj_job_free(c->job);
    free(c);
}

/* Build the command argv (UTF-8) from objv[cmd_index..objc). Caller frees. */
static const char **build_argv(Tcl_Interp *interp, const char *dom, int objc,
                               Tcl_Obj *const objv[], int cmd_index, int *cargc) {
    int n = objc - cmd_index;
    if (n <= 0) return NULL;
    const char **cargv = (const char **)malloc((size_t)n * sizeof(char *));
    if (cargv == NULL) {
        mt_error(interp, dom, "oserror", "out of memory");
        return NULL;
    }
    for (int k = 0; k < n; k++) {
        Tcl_Size len = 0;
        cargv[k] = obj_no_nul(objv[cmd_index + k], &len);
        if (cargv[k] == NULL) {
            free(cargv);
            mt_error(interp, dom, "badvalue", "command arguments may not contain NUL");
            return NULL;
        }
    }
    *cargc = n;
    return cargv;
}

/* ---- live line streaming (run -onout / -onerr) ------------------------- *
 *
 * When a callback is supplied, run does NOT drain the pipe on a reader thread;
 * it pumps both pipes on the interpreter's own thread and evaluates the callback
 * per line -- so the Tcl callback is called from the interp's thread, never a
 * worker (no cross-thread interp access). A pipe with no callback is buffered
 * into its reader_t exactly as the thread would have. */

typedef struct {
    HANDLE    h;        /* pipe read end (borrowed) */
    Tcl_Obj  *cb;       /* callback prefix; NULL => buffer into rd instead */
    reader_t *rd;       /* capture buffer, used when cb == NULL */
    char     *line;     /* partial-line accumulator (cb != NULL) */
    size_t    len, cap;
    int       eof;
} pump_t;

static int valid_utf8(const unsigned char *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned c = s[i++];
        if (c < 0x80) continue;
        unsigned need, min, value;
        if (c >= 0xC2 && c <= 0xDF) { need = 1; min = 0x80; value = c & 0x1F; }
        else if (c >= 0xE0 && c <= 0xEF) { need = 2; min = 0x800; value = c & 0x0F; }
        else if (c >= 0xF0 && c <= 0xF4) { need = 3; min = 0x10000; value = c & 0x07; }
        else return 0;
        if (n - i < need) return 0;
        for (unsigned k = 0; k < need; k++) {
            unsigned d = s[i++];
            if ((d & 0xC0) != 0x80) return 0;
            value = (value << 6) | (d & 0x3F);
        }
        if (value < min || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) return 0;
    }
    return 1;
}

/* Evaluate `cb line` at global scope (the line is one appended argument, no
 * trailing newline). Returns TCL_OK or the callback's error code. */
static int pump_emit(Tcl_Interp *interp, Tcl_Obj *cb, const char *line, size_t len) {
    if (!valid_utf8((const unsigned char *)line, len)) {
        return mt_error(interp, "RUN", "badvalue",
                        "callback output is not valid UTF-8; use captured bytearrays or child -channels for bytes");
    }
    Tcl_Obj *cmd = Tcl_DuplicateObj(cb);
    Tcl_IncrRefCount(cmd);
    int rc = Tcl_ListObjAppendElement(interp, cmd, Tcl_NewStringObj(line, (Tcl_Size)len));
    if (rc == TCL_OK) rc = Tcl_EvalObjEx(interp, cmd, TCL_EVAL_GLOBAL);
    Tcl_DecrRefCount(cmd);
    return rc;
}

/* Append n bytes to a callback pump's line accumulator, emitting each complete
 * line (split on \n; a trailing \r is dropped). Returns TCL_OK or a cb error. */
static int pump_feed(Tcl_Interp *interp, pump_t *p, const char *data, size_t n) {
    for (size_t i = 0; i < n; i++) {
        char ch = data[i];
        if (ch == '\n') {
            size_t l = p->len;
            if (l > 0 && p->line[l - 1] == '\r') l--;
            int rc = pump_emit(interp, p->cb, p->line ? p->line : "", l);
            p->len = 0;
            if (rc != TCL_OK) return rc;
        } else {
            if (p->len + 1 > p->cap) {
                size_t cap = p->cap ? p->cap * 2 : 256;
                char *line = (char *)realloc(p->line, cap);
                if (line == NULL) {
                    return mt_error(interp, "RUN", "oserror", "out of memory while buffering callback line");
                }
                p->line = line;
                p->cap = cap;
            }
            p->line[p->len++] = ch;
        }
    }
    return TCL_OK;
}

/* Read whatever is available on p->h once. Sets *progressed if bytes moved and
 * p->eof at end of pipe. Returns TCL_OK or a callback error. */
static int pump_once(Tcl_Interp *interp, pump_t *p, int *progressed) {
    if (p->eof) return TCL_OK;
    DWORD avail = 0;
    if (!PeekNamedPipe(p->h, NULL, 0, NULL, &avail, NULL)) { p->eof = 1; return TCL_OK; }
    if (avail == 0) return TCL_OK;
    char tmp[8192];
    DWORD want = avail < sizeof(tmp) ? avail : (DWORD)sizeof(tmp);
    DWORD got = 0;
    if (!ReadFile(p->h, tmp, want, &got, NULL) || got == 0) { p->eof = 1; return TCL_OK; }
    *progressed = 1;
    if (p->cb) return pump_feed(interp, p, tmp, (size_t)got);
    reader_t *r = p->rd; /* no callback: buffer like reader_thread, with truncation */
    if (r->len < r->cap) {
        size_t space = r->cap - r->len;
        size_t take = ((size_t)got < space) ? (size_t)got : space;
        memcpy(r->buf + r->len, tmp, take);
        r->len += take;
        if (take < (size_t)got) r->truncated = 1;
    } else {
        r->truncated = 1;
    }
    return TCL_OK;
}

/* Emit a callback pump's trailing partial line (output with no final newline). */
static int pump_flush(Tcl_Interp *interp, pump_t *p) {
    if (p->cb && p->len > 0) {
        size_t l = p->len;
        if (p->line[l - 1] == '\r') l--;
        int rc = pump_emit(interp, p->cb, p->line, l);
        p->len = 0;
        return rc;
    }
    return TCL_OK;
}

/* Pump the child's stdout/stderr on THIS (interp) thread until it exits,
 * streaming lines to -onout/-onerr and/or buffering, honoring -timeout
 * (tree-kill). Sets c->exit_code/killed/timeout and reaps. Returns TCL_OK, or a
 * callback's error code (the child is tree-killed first). */
static int child_pump(Tcl_Interp *interp, child_t *c, run_opts *o) {
    pump_t po = { c->outR, o->onout, &c->ro, NULL, 0, 0, 0 };
    pump_t pe = { c->errR, o->onerr, &c->re, NULL, 0, 0, 0 };
    int rc = TCL_OK;

    for (;;) {
        int progressed = 0;
        rc = pump_once(interp, &po, &progressed);
        if (rc == TCL_OK) rc = pump_once(interp, &pe, &progressed);
        if (rc != TCL_OK) break;

        DWORD w = WaitForSingleObject(c->doneEv, 0);
        if (w == WAIT_OBJECT_0) {
            if (po.eof && pe.eof) break;
        } else if (w != WAIT_TIMEOUT) {
            rc = mt_error(interp, "RUN", "oserror", "waiting for child completion failed");
            break;
        }
        if (!progressed) Sleep(5);
    }

    if (rc != TCL_OK) {
        if (wj_job_terminate(c->job, 1) != 0) wj_job_close(c->job);
        InterlockedExchange(&c->killed, 1);
    }
    if (rc == TCL_OK) {
        rc = pump_flush(interp, &po);
        if (rc == TCL_OK) rc = pump_flush(interp, &pe);
    }

    free(po.line);
    free(pe.line);
    const char *e = NULL;
    if (child_reap(c, WJ_INFINITE, &e) < 0 && rc == TCL_OK)
        rc = mt_error(interp, "RUN", "oserror", e);
    return rc;
}

/* ---- ::machteld::run --------------------------------------------------- */

static int RunCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    proc_ctx *ctx = (proc_ctx *)cd;
    run_opts o;
    unsigned allowed = OPT_TIMEOUT | OPT_MEM | OPT_CPU | OPT_DIR | OPT_ARG0 |
                       OPT_STDIN | OPT_ENV | OPT_ONOUT | OPT_ONERR | OPT_INHERIT;
    if (parse_opts(interp, "RUN", objc, objv, 1, allowed, &o) != TCL_OK) return TCL_ERROR;
    /* Inherit and capture are exclusive, for the reason channels and capture
     * are: there is no pipe of ours to read, so a callback could never fire and
     * `out` would always be empty. Refused rather than silently doing nothing. */
    if (o.inherit && (o.onout != NULL || o.onerr != NULL)) {
        return mt_error(interp, "RUN", "usage",
                        "-inherit cannot be combined with -onout or -onerr: the child writes straight to our stdio");
    }
    if (o.inherit && o.stdin_text != NULL) {
        return mt_error(interp, "RUN", "usage",
                        "-inherit cannot be combined with -stdin: the child reads our stdin");
    }
    int cargc = 0;
    if (o.cmd_index >= objc)
        return mt_error(interp, "RUN", "usage", "run ?-opt val ...? ?--? command ?arg ...?");
    const char **cargv = build_argv(interp, "RUN", objc, objv, o.cmd_index, &cargc);
    if (cargv == NULL) return TCL_ERROR;

    wchar_t envbuf[32768];
    if (o.env_obj != NULL) {
        const char *ee = NULL;
        if (build_env_block(interp, o.env_obj, envbuf, sizeof(envbuf) / sizeof(envbuf[0]), &ee) != 0) {
            free(cargv);
            return mt_error(interp, "RUN", "badvalue", ee);
        }
        o.env_block = envbuf; /* stack buffer, valid through the launch below */
    }

    const char *err = NULL, *code = "launch";
    int stream = (o.onout != NULL || o.onerr != NULL);
    child_t *c = child_launch(ctx, &o, cargc, cargv, 0, stream, &err, &code);
    free(cargv);
    if (c == NULL) return mt_error(interp, "RUN", code, err);

    if (stream) {
        /* live path: pump the pipes on this thread, emitting lines to the
         * callbacks, until the child exits (or -timeout tree-kills it). A
         * callback error aborts the run -- child_pump kills the child first, and
         * the callback's error is already in the interp result. */
        if (child_pump(interp, c, &o) != TCL_OK) { child_free(c); return TCL_ERROR; }
    } else {
        int w = child_reap(c, WJ_INFINITE, &err);
        if (w < 0) { child_free(c); return mt_error(interp, "RUN", "oserror", err); }
    }

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
        return mt_error(interp, "CHILD", "usage", "child subcommand ?arg ...?");
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", TCL_EXACT, &idx) != TCL_OK)
        return mt_error(interp, "CHILD", "usage", "unknown child subcommand");

    if (idx == START) {
        run_opts o;
        unsigned allowed = OPT_TIMEOUT | OPT_MEM | OPT_CPU | OPT_DIR | OPT_ARG0 |
                           OPT_STDIN | OPT_ENV | OPT_CHANNELS;
        if (parse_opts(interp, "CHILD", objc, objv, 2, allowed, &o) != TCL_OK) return TCL_ERROR;
        if (o.channels && o.stdin_text != NULL) {
            return mt_error(interp, "CHILD", "usage",
                            "-channels cannot be combined with -stdin: write to the stdin channel instead");
        }
        int cargc = 0;
        if (o.cmd_index >= objc)
            return mt_error(interp, "CHILD", "usage", "child start ?-opt val ...? ?--? command ?arg ...?");
        const char **cargv = build_argv(interp, "CHILD", objc, objv, o.cmd_index, &cargc);
        if (cargv == NULL) return TCL_ERROR;
        wchar_t envbuf[32768];
        if (o.env_obj != NULL) {
            const char *ee = NULL;
            if (build_env_block(interp, o.env_obj, envbuf, sizeof(envbuf) / sizeof(envbuf[0]), &ee) != 0) {
                free(cargv);
                return mt_error(interp, "CHILD", "badvalue", ee);
            }
            o.env_block = envbuf;
        }
        const char *err = NULL, *code = "launch";
        child_t *c = child_launch(ctx, &o, cargc, cargv, 1, 0, &err, &code);
        free(cargv);
        if (c == NULL) return mt_error(interp, "CHILD", code, err);
        if (o.channels && child_channels(interp, c) != 0) {
            Tcl_Obj *detail = Tcl_DuplicateObj(Tcl_GetObjResult(interp));
            Tcl_IncrRefCount(detail);
            registry_remove(ctx, c);
            child_free(c);
            Tcl_SetObjResult(interp, Tcl_ObjPrintf(
                "cannot configure child channels: %s", Tcl_GetString(detail)));
            Tcl_DecrRefCount(detail);
            Tcl_SetErrorCode(interp, "MACHTELD", "CHILD", "oserror", NULL);
            return TCL_ERROR;
        }
        Tcl_SetObjResult(interp, Tcl_NewStringObj(c->token, -1));
        return TCL_OK;
    }

    if (idx == LIST) {
        if (objc != 2) return mt_error(interp, "CHILD", "usage", "child list");
        Tcl_Obj *l = Tcl_NewListObj(0, NULL);
        for (child_t *c = ctx->children; c; c = c->next) {
            Tcl_ListObjAppendElement(interp, l, Tcl_NewStringObj(c->token, -1));
        }
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }

    /* the rest take a token */
    if (objc < 3) return mt_error(interp, "CHILD", "usage", "child subcommand token ?arg ...?");
    const char *token = Tcl_GetString(objv[2]);
    child_t *c = registry_find(ctx, token);
    if (c == NULL) return mt_error(interp, "CHILD", "nohandle", "no such child");

    switch (idx) {
    case WAIT: {
        const char *err = NULL;
        /* This timeout only bounds the wait; the autonomous start deadline is
         * enforced by the monitor thread. */
        if (objc != 3 && objc != 5)
            return mt_error(interp, "CHILD", "usage", "child wait token ?-timeout duration?");
        long long want = -1;
        if (objc == 5) {
            if (strcmp(Tcl_GetString(objv[3]), "-timeout") != 0)
                return mt_error(interp, "CHILD", "usage", "unknown option");
            want = parse_duration_ms(Tcl_GetString(objv[4]));
            if (want < 0) return mt_error(interp, "CHILD", "badvalue", "bad -timeout value");
            if ((unsigned long long)want >= WJ_INFINITE)
                return mt_error(interp, "CHILD", "badvalue", "bad -timeout value");
        }
        unsigned wait_ms = WJ_INFINITE;
        if (want >= 0) wait_ms = (unsigned)want;
        if (!c->reaped) {
            int w = child_reap(c, wait_ms, &err);
            if (w == 1) {
                Tcl_SetObjResult(interp, child_dict_ex(interp, c, 1));
                return TCL_OK;
            }
            if (w < 0) return mt_error(interp, "CHILD", "oserror", err);
        }
        Tcl_SetObjResult(interp, child_dict(interp, c));
        return TCL_OK;
    }
    case KILL: {
        if (objc != 3 && objc != 4) return mt_error(interp, "CHILD", "usage", "child kill token ?exitCode?");
        unsigned code = 1;
        if (objc >= 4) {
            int v;
            if (Tcl_GetIntFromObj(interp, objv[3], &v) != TCL_OK)
                return mt_error(interp, "CHILD", "badvalue", "bad exit code");
            code = (unsigned)v;
        }
        if (!c->reaped) {
            if (wj_job_terminate(c->job, code) != 0)
                return mt_error(interp, "CHILD", "oserror", "cannot terminate child job");
            InterlockedExchange(&c->killed, 1);
        }
        return TCL_OK;
    }
    case INFO: {
        if (objc != 3) return mt_error(interp, "CHILD", "usage", "child info token");
        Tcl_Obj *d = Tcl_NewDictObj();
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("token", -1), Tcl_NewStringObj(c->token, -1));
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("pid", -1), Tcl_NewIntObj(c->pid));
        int running = 0;
        if (c->reaped) {
            running = 0;
        } else {
            running = WaitForSingleObject(c->doneEv, 0) == WAIT_TIMEOUT;
        }
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("running", -1), Tcl_NewIntObj(running));
        if (c->reaped) {
            Tcl_DictObjPut(interp, d, Tcl_NewStringObj("exit", -1), Tcl_NewWideIntObj((Tcl_WideInt)c->exit_code));
        }
        /* Channel names are present only for children started with -channels. */
        if (c->channels) {
            Tcl_DictObjPut(interp, d, Tcl_NewStringObj("stdin", -1), Tcl_NewStringObj(c->chIn, -1));
            Tcl_DictObjPut(interp, d, Tcl_NewStringObj("stdout", -1), Tcl_NewStringObj(c->chOut, -1));
            Tcl_DictObjPut(interp, d, Tcl_NewStringObj("stderr", -1), Tcl_NewStringObj(c->chErr, -1));
        }
        Tcl_SetObjResult(interp, d);
        return TCL_OK;
    }
    case CLOSE:
        if (objc != 3) return mt_error(interp, "CHILD", "usage", "child close token");
        /* Channels first: closing the stdin channel is what gives the worker its
         * EOF, so a well-behaved worker exits on its own and child_free has
         * nothing to kill. Doing it the other way round would terminate every
         * worker by force and call that normal. */
        child_channels_free(interp, c);
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
    else if (i < objc && Tcl_GetString(objv[i])[0] == '-')
        return mt_error(interp, "WAIT", "usage", "unknown option");
    int n = objc - i;
    if (n <= 0) return mt_error(interp, "WAIT", "usage", "wait ?-any? token ...");
    if (n > MAXIMUM_WAIT_OBJECTS) return mt_error(interp, "WAIT", "usage", "too many children to wait on (max 64)");
    for (int k = 0; k < n; k++) {
        Tcl_Size len = 0;
        const char *tok = obj_no_nul(objv[i + k], &len);
        if (tok == NULL) return mt_error(interp, "WAIT", "badvalue", "handle token may not contain NUL");
        for (int j = 0; j < k; j++) {
            if (strcmp(tok, Tcl_GetString(objv[i + j])) == 0)
                return mt_error(interp, "WAIT", "usage", "duplicate handle token");
        }
    }

    Tcl_Obj *done = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(done);
    HANDLE h[MAXIMUM_WAIT_OBJECTS];
    waitable ws[MAXIMUM_WAIT_OBJECTS];
    for (;;) {
        Tcl_SetListObj(done, 0, NULL);
        int nh = 0;
        for (int k = 0; k < n; k++) {
            const char *tok = Tcl_GetString(objv[i + k]);
            waitable w;
            /* A token names a child or a watch; both are waitable, and `wait` is
             * the one multiplexer over all of them -- so a tool can block on
             * "either the build finished or a file changed" without polling. */
            child_t *c = registry_find(ctx, tok);
            if (c != NULL) {
                w.token = c->token;
                w.h     = c->doneEv;
                w.ready = c->reaped || WaitForSingleObject(c->doneEv, 0) == WAIT_OBJECT_0;
            } else if (!watch_waitable(ctx, tok, &w)) {
                Tcl_DecrRefCount(done);
                return mt_error(interp, "WAIT", "nohandle", "no such child or watch");
            }
            if (w.ready) {
                Tcl_ListObjAppendElement(interp, done, Tcl_NewStringObj(w.token, -1));
            } else {
                h[nh]  = w.h;
                ws[nh] = w;
                nh++;
            }
        }
        /* -any and some are already done, or nothing left to wait on. */
        if (nh == 0 || (any && Tcl_GetCharLength(done) > 0)) break;

        DWORD r = WaitForMultipleObjects((DWORD)nh, h, any ? FALSE : TRUE, INFINITE);
        if (r == WAIT_FAILED) {
            Tcl_DecrRefCount(done);
            return mt_error(interp, "WAIT", "oserror", "waiting for handles failed");
        }
        if (any) {
            if (r < WAIT_OBJECT_0 + (DWORD)nh) {
                Tcl_ListObjAppendElement(interp, done, Tcl_NewStringObj(ws[r - WAIT_OBJECT_0].token, -1));
            } else {
                Tcl_DecrRefCount(done);
                return mt_error(interp, "WAIT", "oserror", "unexpected wait result");
            }
        } else {
            if (r != WAIT_OBJECT_0) {
                Tcl_DecrRefCount(done);
                return mt_error(interp, "WAIT", "oserror", "unexpected wait result");
            }
            for (int k = 0; k < nh; k++) {
                Tcl_ListObjAppendElement(interp, done, Tcl_NewStringObj(ws[k].token, -1));
            }
        }
        break;
    }
    Tcl_SetObjResult(interp, done);
    Tcl_DecrRefCount(done);
    return TCL_OK;
}

/* ---- ::machteld::detach ------------------------------------------------ */

/* Launch a fire-and-forget daemon with NUL stdio. Breakaway is strict: failure
 * is reported rather than returning a PID for a process still tied to us. */
static int DetachCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    run_opts o;
    unsigned allowed = OPT_DIR | OPT_ARG0 | OPT_ENV;
    if (parse_opts(interp, "DETACH", objc, objv, 1, allowed, &o) != TCL_OK) return TCL_ERROR;
    int cargc = 0;
    if (o.cmd_index >= objc)
        return mt_error(interp, "DETACH", "usage", "detach ?-opt val ...? ?--? command ?arg ...?");
    const char **cargv = build_argv(interp, "DETACH", objc, objv, o.cmd_index, &cargc);
    if (cargv == NULL) return TCL_ERROR;
    char *exe = resolve_exe(cargv[0]);
    if (exe == NULL) { free(cargv); return mt_error(interp, "DETACH", "notfound", "command not found on PATH"); }

    int         result = TCL_ERROR;
    const char *err = NULL;
    HANDLE      nul = NULL;
    void       *proch = NULL;
    int         pid = 0;

    wchar_t envbuf[32768];
    if (o.env_obj != NULL) {
        const char *ee = NULL;
        if (build_env_block(interp, o.env_obj, envbuf, sizeof(envbuf) / sizeof(envbuf[0]), &ee) != 0) {
            mt_error(interp, "DETACH", "badvalue", ee);
            goto cleanup;
        }
        o.env_block = envbuf; /* stack buffer, valid through the launch below */
    }

    nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                      NULL, OPEN_EXISTING, 0, NULL);
    if (nul == INVALID_HANDLE_VALUE) { nul = NULL; mt_error(interp, "DETACH", "oserror", "open NUL failed"); goto cleanup; }
    wj_stdio io = { nul, nul, nul };
    const char **dargv = argv_with_arg0(&o, cargc, cargv, &err);
    if (dargv == NULL) { mt_error(interp, "DETACH", "oserror", err); goto cleanup; }
    int drc = wj_launch(exe, cargc, dargv, o.dir, NULL, 0, &io,
                        1 /* strict breakaway */, o.env_block, &pid, &proch, &err);
    if (dargv != cargv) free((void *)dargv);
    if (drc != 0) {
        mt_error(interp, "DETACH", "launch", err);
        goto cleanup;
    }
    Tcl_SetObjResult(interp, Tcl_NewIntObj(pid));
    result = TCL_OK;

cleanup:
    if (proch) wj_proc_close(proch); /* stop supervising; the daemon runs on */
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
 * pipes. It is born into the root and its per-PTY job like every supervised
 * child, so it stays supervised. Output is the raw VT/ANSI byte stream.
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

static int pty_free(proc_ctx *ctx, pty_t *p) {
    int failed = 0;
    /* Drain concurrently while closing the pseudo-console so its final output
     * cannot block console-host teardown. */
    HANDLE drain = NULL;
    if (p->outR != NULL) {
        drain = CreateThread(NULL, 0, pty_drain_thread, p->outR, 0, NULL);
        if (drain == NULL) return -1;
    }
    pty_t **pp = &ctx->ptys;
    while (*pp) { if (*pp == p) { *pp = p->next; break; } pp = &(*pp)->next; }
    if (p->job && wj_job_terminate(p->job, 1) != 0) {
        wj_job_close(p->job);
        failed = 1;
    }
    if (p->inW) { CloseHandle(p->inW); p->inW = NULL; }
    if (p->hpc) { ClosePseudoConsole(p->hpc); p->hpc = NULL; }
    if (drain) {
        DWORD wr = WaitForSingleObject(drain, 5000);
        if (wr != WAIT_OBJECT_0) {
            CancelSynchronousIo(drain);
            wr = WaitForSingleObject(drain, 5000);
        }
        if (wr != WAIT_OBJECT_0) {
            CloseHandle(drain);
            return -1; /* p remains allocated because the thread may still read its handle */
        }
        CloseHandle(drain);
    }
    if (p->outR) { CloseHandle(p->outR); p->outR = NULL; }
    if (p->proc) wj_proc_close(p->proc);
    if (p->job) wj_job_free(p->job);
    free(p);
    return failed ? -1 : 0;
}

/* *code as in child_launch: `notfound` for an unresolvable program, `launch`
 * for anything that fails once the program has been found. */
static pty_t *pty_spawn(proc_ctx *ctx, run_opts *o, int cargc, const char **cargv,
                        int cols, int rows, const char **err, const char **code) {
    char *exe = resolve_exe(cargv[0]);
    if (exe == NULL) { *err = "command not found on PATH"; *code = "notfound"; return NULL; }
    const char **pargv = argv_with_arg0(o, cargc, cargv, err);
    if (pargv == NULL) { free(exe); return NULL; }

    HANDLE   inR = NULL, inW = NULL, outR = NULL, outW = NULL;
    HPCON    hpc = NULL;
    wj_job  *job = NULL;
    pty_t   *result = NULL;
    void    *proc = NULL;
    int      pid = 0;

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

    job = wj_job_new(1, err);
    if (job == NULL) goto done;
    if (o->mem || o->cpu_100ns) {
        wj_limits lim = { 0 };
        lim.process_memory_bytes = o->mem; lim.process_cpu_100ns = o->cpu_100ns;
        if (wj_job_set_limits(job, &lim, err) != 0) goto done;
    }

    void *jobh[2];
    jobh[0] = wj_job_handle(ctx->root);
    jobh[1] = wj_job_handle(job);
    int njobs = 2;

    result = (pty_t *)calloc(1, sizeof(*result));
    if (result == NULL) { *err = "out of memory"; goto done; }
    if (wj_launch_pty(exe, cargc, pargv, o->dir, jobh, njobs, hpc,
                      o->env_block, &pid, &proc, err) != 0) goto done;

    result->hpc = hpc; result->job = job; result->proc = proc;
    result->pid = pid; result->inW = inW; result->outR = outR;
    snprintf(result->token, sizeof result->token, "pty#%d", ++ctx->pty_counter);
    result->next = ctx->ptys; ctx->ptys = result;
    hpc = NULL; job = NULL; inW = NULL; outR = NULL; /* ownership moved to result */

done:
    if (pargv != cargv) free((void *)pargv);
    free(exe);
    if (inR) CloseHandle(inR);
    if (outW) CloseHandle(outW);
    if (result == NULL) { /* failure: unwind what we made */
        if (proc && job) (void)wj_job_terminate(job, 1);
        if (proc) wj_proc_close(proc);
        if (inW) CloseHandle(inW);
        if (outR) CloseHandle(outR);
        if (hpc) ClosePseudoConsole(hpc);
        if (job) wj_job_free(job);
    } else if (result->proc == NULL) {
        free(result);
        result = NULL;
        if (inW) CloseHandle(inW);
        if (outR) CloseHandle(outR);
        if (hpc) ClosePseudoConsole(hpc);
        if (job) wj_job_free(job);
    }
    return result;
}

static int PtyCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    proc_ctx *ctx = (proc_ctx *)cd;
    static const char *const subs[] = { "spawn", "send", "read", "close", "list", "info", NULL };
    enum { SPAWN, SEND, READ, CLOSE, LIST, INFO };
    int idx;
    if (objc < 2) return mt_error(interp, "PTY", "usage", "pty subcommand ?arg ...?");
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", TCL_EXACT, &idx) != TCL_OK)
        return mt_error(interp, "PTY", "usage", "unknown pty subcommand");

    if (idx == SPAWN) {
        run_opts o;
        unsigned allowed = OPT_MEM | OPT_CPU | OPT_DIR | OPT_ARG0 | OPT_ENV;
        if (parse_opts(interp, "PTY", objc, objv, 2, allowed, &o) != TCL_OK) return TCL_ERROR;
        int cargc = 0;
        if (o.cmd_index >= objc)
            return mt_error(interp, "PTY", "usage", "pty spawn ?-opt val ...? ?--? command ?arg ...?");
        const char **cargv = build_argv(interp, "PTY", objc, objv, o.cmd_index, &cargc);
        if (cargv == NULL) return TCL_ERROR;
        wchar_t envbuf[32768];
        if (o.env_obj != NULL) {
            const char *ee = NULL;
            if (build_env_block(interp, o.env_obj, envbuf, sizeof(envbuf) / sizeof(envbuf[0]), &ee) != 0) {
                free(cargv);
                return mt_error(interp, "PTY", "badvalue", ee);
            }
            o.env_block = envbuf;
        }
        const char *err = NULL, *code = "launch";
        pty_t *p = pty_spawn(ctx, &o, cargc, cargv, 80, 25, &err, &code);
        free(cargv);
        if (p == NULL) return mt_error(interp, "PTY", code, err);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(p->token, -1));
        return TCL_OK;
    }
    if (idx == LIST) {
        if (objc != 2) return mt_error(interp, "PTY", "usage", "pty list");
        Tcl_Obj *l = Tcl_NewListObj(0, NULL);
        for (pty_t *p = ctx->ptys; p; p = p->next) {
            Tcl_ListObjAppendElement(interp, l, Tcl_NewStringObj(p->token, -1));
        }
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }

    if (objc < 3) return mt_error(interp, "PTY", "usage", "pty subcommand token ?arg ...?");
    pty_t *p = pty_find(ctx, Tcl_GetString(objv[2]));
    if (p == NULL) return mt_error(interp, "PTY", "nohandle", "no such pty");

    switch (idx) {
    /* INFO LOOKS WITHOUT TAKING. `pty read` consumes the child's output, so a
     * monitor built on it would eat the very bytes the program is steering by.
     * PeekNamedPipe reports how much is waiting and leaves it in the pipe, which
     * is the only honest way to show "this terminal has something to say". */
    case INFO: {
        if (objc != 3) return mt_error(interp, "PTY", "usage", "pty info token");
        Tcl_Obj *d = Tcl_NewDictObj();
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("token", -1), Tcl_NewStringObj(p->token, -1));
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("pid", -1), Tcl_NewIntObj(p->pid));
        const char *e = NULL;
        unsigned active = 0;
        if (wj_job_active(p->job, &active, &e) != 0)
            return mt_error(interp, "PTY", "oserror", e);
        int running = active > 0;
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("running", -1), Tcl_NewIntObj(running));
        DWORD avail = 0;
        if (!PeekNamedPipe(p->outR, NULL, 0, NULL, &avail, NULL)) avail = 0;
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("pending", -1), Tcl_NewWideIntObj((Tcl_WideInt)avail));
        Tcl_SetObjResult(interp, d);
        return TCL_OK;
    }
    case SEND: {
        if (objc != 4) return mt_error(interp, "PTY", "usage", "pty send token bytes");
        Tcl_Size len;
        const char *s = Tcl_GetStringFromObj(objv[3], &len);
        size_t off = 0;
        while (off < (size_t)len) {
            size_t left = (size_t)len - off;
            DWORD want = left > (size_t)0x7ffff000u ? 0x7ffff000u : (DWORD)left;
            DWORD written = 0;
            if (!WriteFile(p->inW, s + off, want, &written, NULL) || written == 0)
                return mt_error(interp, "PTY", "oserror", "write to pty failed");
            off += written;
        }
        return TCL_OK;
    }
    case READ: {
        if (objc != 3 && objc != 5)
            return mt_error(interp, "PTY", "usage", "pty read token ?-timeout duration?");
        DWORD timeout_ms = 0;
        if (objc == 5) {
            if (strcmp(Tcl_GetString(objv[3]), "-timeout") != 0)
                return mt_error(interp, "PTY", "usage", "unknown option");
            long long t = parse_duration_ms(Tcl_GetString(objv[4]));
            if (t < 0 || (unsigned long long)t >= WJ_INFINITE)
                return mt_error(interp, "PTY", "badvalue", "bad -timeout value");
            timeout_ms = (DWORD)t;
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
        if (objc != 3) return mt_error(interp, "PTY", "usage", "pty close token");
        if (pty_free(ctx, p) != 0)
            return mt_error(interp, "PTY", "oserror", "pty teardown failed");
        return TCL_OK;
    }
    return TCL_OK;
}

/* ---- ::machteld::watch (ReadDirectoryChangesW) -------------------------- *
 * A worker owns overlapped directory I/O and queues plain UTF-8 records. Tcl
 * objects are created only on the interpreter thread. */

typedef struct {
    int   action;   /* FILE_ACTION_* */
    char *path;     /* UTF-8, relative to the watched directory */
    char *from;     /* the old name, once a rename pair has been joined */
    int   done;     /* consumed by coalescing */
} wevent;

#define WATCH_QUEUE_MAX 8192

typedef struct watch_s {
    char    token[24];
    HANDLE  dir;        /* the directory, opened FILE_LIST_DIRECTORY */
    HANDLE  thread;
    HANDLE  stopEv;     /* manual-reset: tells the reader thread to leave */
    HANDLE  dataEv;     /* manual-reset: events are queued (what `wait` blocks on) */
    HANDLE  readyEv;    /* manual-reset: the first read is ISSUED, so nothing is missed */
    int     armed;      /* did that first read actually take? */
    int     failed;
    DWORD   error;
    CRITICAL_SECTION lock;
    wevent *ev;
    size_t  n, cap;
    int     dropped;    /* events lost to the queue cap or an OS buffer overflow */
    int     recursive;
    char   *dir_path;   /* for diagnostics */
    struct watch_s *next;
} watch_t;

static void watch_fail(watch_t *w, DWORD error) {
    EnterCriticalSection(&w->lock);
    w->failed = 1;
    w->error = error ? error : ERROR_GEN_FAILURE;
    LeaveCriticalSection(&w->lock);
    SetEvent(w->readyEv);
    SetEvent(w->dataEv);
}

static watch_t *watch_find(proc_ctx *ctx, const char *token) {
    for (watch_t *w = ctx->watches; w; w = w->next) {
        if (strcmp(w->token, token) == 0) return w;
    }
    return NULL;
}

/* Queue one event. Caller holds the lock. Over the cap we count rather than
 * grow without bound: a watch on a busy tree must not be able to exhaust memory,
 * and a caller that fell behind is told so rather than quietly given less. */
static void watch_push(watch_t *w, int action, const char *path) {
    if (w->n >= WATCH_QUEUE_MAX) { w->dropped++; return; }
    if (w->n == w->cap) {
        size_t cap = w->cap ? w->cap * 2 : 64;
        wevent *ev = (wevent *)realloc(w->ev, cap * sizeof(*ev));
        if (ev == NULL) { w->dropped++; return; }
        w->ev = ev;
        w->cap = cap;
    }
    char *dup = _strdup(path);
    if (dup == NULL) { w->dropped++; return; }
    /* Every field, explicitly: the array comes from realloc, so anything left
     * unset is whatever was in that memory -- and a garbage `done` silently
     * swallows the event during coalescing. */
    w->ev[w->n].action = action;
    w->ev[w->n].path   = dup;
    w->ev[w->n].from   = NULL;
    w->ev[w->n].done   = 0;
    w->n++;
}

static DWORD WINAPI watch_thread(LPVOID arg) {
    watch_t *w = (watch_t *)arg;
    /* DWORD-aligned, and large enough that ordinary bursts do not overflow it. */
    char *buf = (char *)malloc(64 * 1024);
    if (buf == NULL) { watch_fail(w, ERROR_NOT_ENOUGH_MEMORY); return 0; }
    OVERLAPPED ov;
    HANDLE ioEv = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (ioEv == NULL) { DWORD e = GetLastError(); free(buf); watch_fail(w, e); return 0; }

    const DWORD filter = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
                         FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE |
                         FILE_NOTIFY_CHANGE_CREATION;
    int first = 1;
    for (;;) {
        memset(&ov, 0, sizeof ov);
        ov.hEvent = ioEv;
        ResetEvent(ioEv);
        BOOL ok = ReadDirectoryChangesW(w->dir, buf, 64 * 1024, w->recursive,
                                        filter, NULL, &ov, NULL);
        if (first) {
            /* `watch start` blocks until this point. Returning as soon as the
             * THREAD exists is not enough: until the first read is actually
             * issued the OS is not recording anything, so a change made
             * immediately after start would be missed -- silently, which is the
             * worst way to miss it. Signal armed-or-failed either way, so a
             * failure surfaces at start instead of as permanent silence. */
            first = 0;
            w->armed = ok ? 1 : 0;
            SetEvent(w->readyEv);
        }
        if (!ok) { watch_fail(w, GetLastError()); break; }
        HANDLE hs[2] = { ioEv, w->stopEv };
        DWORD r = WaitForMultipleObjects(2, hs, FALSE, INFINITE);
        if (r == WAIT_OBJECT_0 + 1) {
            /* Stop requested: withdraw the read and reap it before leaving, so
             * the buffer is not written after this thread frees it. */
            CancelIoEx(w->dir, &ov);
            DWORD got = 0;
            GetOverlappedResult(w->dir, &ov, &got, TRUE);
            break;
        }
        if (r != WAIT_OBJECT_0) {
            watch_fail(w, GetLastError());
            break;
        }
        DWORD got = 0;
        if (!GetOverlappedResult(w->dir, &ov, &got, FALSE)) {
            watch_fail(w, GetLastError());
            break;
        }

        EnterCriticalSection(&w->lock);
        if (got == 0) {
            /* The OS buffer overflowed: changes happened that it could not
             * describe. Say so rather than pretending nothing did. */
            w->dropped++;
        } else {
            size_t off = 0;
            const size_t header = offsetof(FILE_NOTIFY_INFORMATION, FileName);
            while (off + header <= (size_t)got) {
                char *p = buf + off;
                FILE_NOTIFY_INFORMATION *fni = (FILE_NOTIFY_INFORMATION *)p;
                if ((fni->FileNameLength & 1u) != 0 ||
                    (size_t)fni->FileNameLength > (size_t)got - off - header) {
                    w->failed = 1; w->error = ERROR_INVALID_DATA;
                    break;
                }
                int wlen = (int)(fni->FileNameLength / sizeof(WCHAR));
                int need = WideCharToMultiByte(CP_UTF8, 0, fni->FileName, wlen, NULL, 0, NULL, NULL);
                if (need > 0) {
                    char *u8 = (char *)malloc((size_t)need + 1);
                    if (u8 != NULL) {
                        WideCharToMultiByte(CP_UTF8, 0, fni->FileName, wlen, u8, need, NULL, NULL);
                        u8[need] = '\0';
                        for (char *c = u8; *c; c++) { if (*c == '\\') *c = '/'; }
                        watch_push(w, (int)fni->Action, u8);
                        free(u8);
                    }
                }
                if (fni->NextEntryOffset == 0) break;
                if ((size_t)fni->NextEntryOffset < header ||
                    (size_t)fni->NextEntryOffset > (size_t)got - off) {
                    w->failed = 1; w->error = ERROR_INVALID_DATA;
                    break;
                }
                off += fni->NextEntryOffset;
            }
        }
        if (w->n > 0 || w->dropped > 0 || w->failed) SetEvent(w->dataEv);
        int failed = w->failed;
        LeaveCriticalSection(&w->lock);
        if (failed) break;
    }
    CloseHandle(ioEv);
    free(buf);
    return 0;
}

static int watch_free(proc_ctx *ctx, watch_t *w) {
    watch_t **pp = &ctx->watches;
    while (*pp) { if (*pp == w) { *pp = w->next; break; } pp = &(*pp)->next; }
    if (w->stopEv) SetEvent(w->stopEv);
    if (w->thread) {
        DWORD r = WaitForSingleObject(w->thread, 5000);
        if (r == WAIT_TIMEOUT) {
            CancelIoEx(w->dir, NULL);
            if (w->dir && w->dir != INVALID_HANDLE_VALUE) {
                CloseHandle(w->dir);
                w->dir = NULL;
            }
            r = WaitForSingleObject(w->thread, 5000);
        }
        if (r != WAIT_OBJECT_0) {
            /* The thread still owns this structure. Leak it rather than freeing
             * memory it may access; the close command reports the failure. */
            return -1;
        }
        CloseHandle(w->thread);
    }
    if (w->dir && w->dir != INVALID_HANDLE_VALUE) CloseHandle(w->dir);
    if (w->stopEv) CloseHandle(w->stopEv);
    if (w->dataEv) CloseHandle(w->dataEv);
    if (w->readyEv) CloseHandle(w->readyEv);
    DeleteCriticalSection(&w->lock);
    for (size_t i = 0; i < w->n; i++) free(w->ev[i].path);
    free(w->ev);
    free(w->dir_path);
    free(w);
    return 0;
}

/* The `wait` seam: a watch is ready when it has something queued. */
static int watch_waitable(proc_ctx *ctx, const char *token, waitable *out) {
    watch_t *w = watch_find(ctx, token);
    if (w == NULL) return 0;
    EnterCriticalSection(&w->lock);
    int ready = (w->n > 0 || w->dropped > 0 || w->failed);
    LeaveCriticalSection(&w->lock);
    out->token = w->token;
    out->h     = w->dataEv;
    out->ready = ready;
    return 1;
}

static const char *watch_action_name(int action) {
    switch (action) {
        case FILE_ACTION_ADDED:            return "added";
        case FILE_ACTION_REMOVED:          return "removed";
        case FILE_ACTION_MODIFIED:         return "modified";
        case FILE_ACTION_RENAMED_OLD_NAME: return "renamed-old";
        case FILE_ACTION_RENAMED_NEW_NAME: return "renamed-new";
    }
    return "unknown";
}

static Tcl_Obj *watch_event_obj(const char *path, const char *action, const char *from) {
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("path", -1), Tcl_NewStringObj(path, -1));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("action", -1), Tcl_NewStringObj(action, -1));
    if (from != NULL) {
        Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("from", -1), Tcl_NewStringObj(from, -1));
    }
    return d;
}

static int WatchCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    proc_ctx *ctx = (proc_ctx *)cd;
    static const char *const subs[] = { "start", "read", "close", "list", "info", NULL };
    enum { START, READ, CLOSE, LIST, INFO };
    int idx;
    if (objc < 2) {
        return mt_error(interp, "WATCH", "usage", "watch subcommand ?arg ...?");
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", TCL_EXACT, &idx) != TCL_OK)
        return mt_error(interp, "WATCH", "usage", "unknown watch subcommand");

    if (idx == START) {
        if (objc != 3 && objc != 4)
            return mt_error(interp, "WATCH", "usage", "watch start dir ?-recursive?");
        const char *dir = Tcl_GetString(objv[2]);
        int recursive = 0;
        for (int i = 3; i < objc; i++) {
            const char *a = Tcl_GetString(objv[i]);
            if (strcmp(a, "-recursive") == 0) { recursive = 1; }
            else return mt_error(interp, "WATCH", "usage", "unknown option");
        }
        wchar_t *wdir = u8_to_u16(dir);
        if (wdir == NULL) return mt_error(interp, "WATCH", "badvalue", "bad directory name");
        HANDLE h = CreateFileW(wdir, FILE_LIST_DIRECTORY,
                               FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                               NULL, OPEN_EXISTING,
                               FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
        free(wdir);
        if (h == INVALID_HANDLE_VALUE) {
            return mt_error(interp, "WATCH", "notfound", "cannot open directory to watch");
        }
        watch_t *w = (watch_t *)calloc(1, sizeof(*w));
        if (w == NULL) { CloseHandle(h); return mt_error(interp, "WATCH", "oserror", "out of memory"); }
        w->dir = h;
        w->recursive = recursive;
        w->dir_path = _strdup(dir);
        InitializeCriticalSection(&w->lock);
        w->stopEv  = CreateEventW(NULL, TRUE, FALSE, NULL);
        w->dataEv  = CreateEventW(NULL, TRUE, FALSE, NULL);
        w->readyEv = CreateEventW(NULL, TRUE, FALSE, NULL);
        if (w->dir_path == NULL || w->stopEv == NULL || w->dataEv == NULL || w->readyEv == NULL) {
            watch_free(ctx, w);
            return mt_error(interp, "WATCH", "oserror", "cannot allocate watch resources");
        }
        snprintf(w->token, sizeof w->token, "watch#%d", ++ctx->watch_counter);
        w->next = ctx->watches;
        ctx->watches = w;
        w->thread = CreateThread(NULL, 0, watch_thread, w, 0, NULL);
        if (w->thread == NULL) {
            watch_free(ctx, w);
            return mt_error(interp, "WATCH", "oserror", "cannot start watch thread");
        }
        /* Do not hand back a token until the watch is actually recording. */
        if (WaitForSingleObject(w->readyEv, 5000) != WAIT_OBJECT_0 || !w->armed) {
            watch_free(ctx, w);
            return mt_error(interp, "WATCH", "oserror", "cannot arm directory watch");
        }
        Tcl_SetObjResult(interp, Tcl_NewStringObj(w->token, -1));
        return TCL_OK;
    }

    if (idx == LIST) {
        if (objc != 2) return mt_error(interp, "WATCH", "usage", "watch list");
        Tcl_Obj *l = Tcl_NewListObj(0, NULL);
        for (watch_t *w = ctx->watches; w; w = w->next) {
            Tcl_ListObjAppendElement(interp, l, Tcl_NewStringObj(w->token, -1));
        }
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }

    if (objc < 3) return mt_error(interp, "WATCH", "usage", "watch subcommand token ?arg ...?");
    watch_t *w = watch_find(ctx, Tcl_GetString(objv[2]));
    if (w == NULL) return mt_error(interp, "WATCH", "nohandle", "no such watch");

    /* Info reads queue state without consuming events. */
    if (idx == INFO) {
        if (objc != 3) return mt_error(interp, "WATCH", "usage", "watch info token");
        Tcl_Obj *d = Tcl_NewDictObj();
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("token", -1), Tcl_NewStringObj(w->token, -1));
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("directory", -1),
                       Tcl_NewStringObj(w->dir_path ? w->dir_path : "", -1));
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("recursive", -1), Tcl_NewIntObj(w->recursive));
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("armed", -1), Tcl_NewIntObj(w->armed));
        EnterCriticalSection(&w->lock);
        size_t pending = w->n;
        int dropped = w->dropped;
        int failed = w->failed;
        DWORD watch_error = w->error;
        LeaveCriticalSection(&w->lock);
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("pending", -1), Tcl_NewWideIntObj((Tcl_WideInt)pending));
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("dropped", -1), Tcl_NewIntObj(dropped));
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("failed", -1), Tcl_NewIntObj(failed));
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj("win32", -1),
                       Tcl_NewWideIntObj(watch_error));
        Tcl_SetObjResult(interp, d);
        return TCL_OK;
    }

    if (idx == CLOSE) {
        if (objc != 3) return mt_error(interp, "WATCH", "usage", "watch close token");
        if (watch_free(ctx, w) != 0)
            return mt_error(interp, "WATCH", "oserror", "watch thread did not stop");
        return TCL_OK;
    }
    if (idx != READ) return TCL_OK;

    /* -timeout waits for the first event; -raw disables coalescing. */
    long long tmo = 0;
    int raw = 0;
    int saw_timeout = 0;
    if (idx == READ) {
        for (int i = 3; i < objc; i++) {
            const char *a = Tcl_GetString(objv[i]);
            if (strcmp(a, "-raw") == 0) {
                if (raw) return mt_error(interp, "WATCH", "usage", "duplicate -raw option");
                raw = 1;
                continue;
            }
            if (strcmp(a, "-timeout") == 0) {
                if (saw_timeout) return mt_error(interp, "WATCH", "usage", "duplicate -timeout option");
                if (i + 1 >= objc) return mt_error(interp, "WATCH", "usage", "option needs a value");
                tmo = parse_duration_ms(Tcl_GetString(objv[++i]));
                if (tmo < 0 || (unsigned long long)tmo >= WJ_INFINITE)
                    return mt_error(interp, "WATCH", "badvalue", "bad -timeout value");
                saw_timeout = 1;
                continue;
            }
            return mt_error(interp, "WATCH", "usage", "unknown option");
        }
    }
    if (tmo > 0) {
        EnterCriticalSection(&w->lock);
        int have = (w->n > 0 || w->dropped > 0);
        LeaveCriticalSection(&w->lock);
        if (!have) {
            DWORD wr = WaitForSingleObject(w->dataEv, (DWORD)tmo);
            if (wr != WAIT_OBJECT_0 && wr != WAIT_TIMEOUT)
                return mt_error(interp, "WATCH", "oserror", "waiting for watch events failed");
        }
    }

    EnterCriticalSection(&w->lock);
    if (w->failed) {
        DWORD watch_error = w->error;
        LeaveCriticalSection(&w->lock);
        char msg[96];
        snprintf(msg, sizeof msg, "directory watch failed (error %lu)", (unsigned long)watch_error);
        return mt_error(interp, "WATCH", "oserror", msg);
    }
    size_t n = w->n;
    wevent *ev = w->ev;
    int dropped = w->dropped;
    w->ev = NULL; w->n = 0; w->cap = 0; w->dropped = 0;
    ResetEvent(w->dataEv);
    LeaveCriticalSection(&w->lock);

    Tcl_Obj *out = Tcl_NewListObj(0, NULL);
    if (dropped > 0) {
        Tcl_Obj *d = watch_event_obj("", "overflow", NULL);
        Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("count", -1), Tcl_NewIntObj(dropped));
        Tcl_ListObjAppendElement(interp, out, d);
    }
    if (raw) {
        for (size_t i = 0; i < n; i++) {
            Tcl_ListObjAppendElement(interp, out,
                watch_event_obj(ev[i].path, watch_action_name(ev[i].action), NULL));
        }
    } else {
        /* Coalesce deterministically per read batch. Action precedence is
         * removed, added, renamed, then modified. */
        for (size_t i = 0; i < n; i++) {
            if (ev[i].action != FILE_ACTION_RENAMED_OLD_NAME || ev[i].done) continue;
            for (size_t j = i + 1; j < n; j++) {
                if (!ev[j].done && ev[j].action == FILE_ACTION_RENAMED_NEW_NAME) {
                    ev[j].from = ev[i].path;   /* borrowed; freed with ev[i] */
                    ev[i].done = 1;
                    break;
                }
            }
        }
        for (size_t i = 0; i < n; i++) {
            if (ev[i].done || ev[i].path == NULL) continue;
            const char *path = ev[i].path;
            int removed = 0, added = 0, renamed = 0;
            const char *from = NULL;
            for (size_t j = i; j < n; j++) {
                if (ev[j].done || ev[j].path == NULL || strcmp(ev[j].path, path) != 0) continue;
                switch (ev[j].action) {
                    /* These are monotonic observations. Clearing the opposite
                     * flag made the last of removed/added win, so an identical
                     * batch could violate the documented precedence solely
                     * because Windows reported its lower-priority event later. */
                    case FILE_ACTION_REMOVED:          removed = 1; break;
                    case FILE_ACTION_ADDED:            added = 1; break;
                    case FILE_ACTION_RENAMED_NEW_NAME: renamed = 1; if (ev[j].from) from = ev[j].from; break;
                    default: break;
                }
                if (j != i) ev[j].done = 1;
            }
            const char *act = removed ? "removed" : added ? "added"
                            : renamed ? "renamed" : watch_action_name(ev[i].action);
            Tcl_ListObjAppendElement(interp, out, watch_event_obj(path, act, from));
        }
    }
    for (size_t i = 0; i < n; i++) free(ev[i].path);
    free(ev);
    Tcl_SetObjResult(interp, out);
    return TCL_OK;
}

/* ---- registration ------------------------------------------------------ */

/* Tear down any open pseudo-consoles and watches at exit, so a REPL user who
 * spawns one and just quits leaves no wedged console host or reader thread. */
static void proc_cleanup(void *cd) {
    proc_ctx *ctx = (proc_ctx *)cd;
    while (ctx->children) {
        child_t *c = ctx->children;
        ctx->children = c->next;
        child_free(c);
    }
    while (ctx->ptys) {
        if (pty_free(ctx, ctx->ptys) != 0) break;
    }
    while (ctx->watches) {
        if (watch_free(ctx, ctx->watches) != 0) break;
    }
    if (ctx->root) wj_job_free(ctx->root);
}

static void proc_atexit(void *cd) {
    proc_cleanup(cd);
}

int Machteldproc_Init(Tcl_Interp *interp) {
    const char *err = NULL;
    wj_job *root = wj_job_new(1, &err); /* closing the root kills every supervised tree */
    if (root == NULL) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(err ? err : "root job creation failed", -1));
        return TCL_ERROR;
    }
    proc_ctx *ctx = (proc_ctx *)calloc(1, sizeof(*ctx));
    if (ctx == NULL) {
        wj_job_free(root);
        Tcl_SetObjResult(interp, Tcl_NewStringObj("out of memory", -1));
        return TCL_ERROR;
    }
    ctx->root = root;

    if (Tcl_Eval(interp, "namespace eval ::machteld {}") != TCL_OK ||
        Tcl_PkgProvide(interp, "machteld::proc", MACHTELD_VERSION) != TCL_OK) {
        proc_cleanup(ctx);
        free(ctx);
        return TCL_ERROR;
    }
    Tcl_CreateObjCommand(interp, "::machteld::run", RunCmd, ctx, NULL);
    Tcl_CreateObjCommand(interp, "::machteld::child", ChildCmd, ctx, NULL);
    Tcl_CreateObjCommand(interp, "::machteld::wait", WaitCmd, ctx, NULL);
    Tcl_CreateObjCommand(interp, "::machteld::detach", DetachCmd, ctx, NULL);
    Tcl_CreateObjCommand(interp, "::machteld::pty", PtyCmd, ctx, NULL);
    Tcl_CreateObjCommand(interp, "::machteld::watch", WatchCmd, ctx, NULL);
    Tcl_CreateExitHandler(proc_atexit, ctx);
    return TCL_OK;
}
