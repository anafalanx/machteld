/* engine.c -- Machteld's engine mode: the third face of the executable.
 *
 * Entered via the reserved host word `--machteld-engine` BEFORE any Tcl or
 * zipfs work: this process initializes no Tcl and no Tk. It is a disposable
 * compute child speaking protocol 1 of docs/engine.md over binary stdio
 * frames (uint32le length + one UTF-8 JSON object), holding Lua 5.5 states
 * and typed data pools, supervised and killed by the host through the job
 * machinery. The engine is a cache, never the truth: any state here may be
 * killed at any instant and rebuilt by the host.
 *
 * Threading law (from reken, unchanged): each lua_State is touched by
 * exactly one thread at a time; workers touch only their own state;
 * allocation is CRT malloc, metered per state by the counting allocator.
 * The parsed request tree (Ej) is read-only and safely shared by workers.
 *
 * Capabilities: lua, load.lines, shards, reduce, stats; the csv loader
 * arrives behind the same hello negotiation. The kernel environment is
 * Lua 5.5 with base/string/math/table/utf8 plus the vendored LPeg and
 * lua-cjson - pure computation, no ambient authority.
 */

#include "machteld.h"            /* MACHTELD_VERSION + the entry prototype */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#undef WIN32_LEAN_AND_MEAN
#include <process.h>
#include <io.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "engine_json.h"
#include "engine_int.h"

#define ENGINE_PROTOCOL     1
#define ENGINE_MAXSTATES    32
#define ENGINE_FRAME_MAX    (64u * 1024u * 1024u)
#define ENGINE_VALUE_CEIL   (1u * 1024u * 1024u)
#define ENGINE_STATE_CAP_MB 256
#define ENGINE_MAX_KERNELS  256
#define ENGINE_MAX_POOLS    64
#define ENGINE_MAX_RESULTS  256
#define ENGINE_CONV_DEPTH   32

/* ---------------- metered states (reken lineage) ---------------- */

typedef struct {
    size_t used;
    size_t cap;
} EngAlloc;

static void *
EngAllocF(void *ud, void *ptr, size_t osize, size_t nsize)
{
    EngAlloc *a = (EngAlloc *)ud;
    size_t old = (ptr != NULL) ? osize : 0;
    if (nsize == 0) {
        a->used -= old;
        free(ptr);
        return NULL;
    }
    if (a->cap != 0 && nsize > old && a->used - old + nsize > a->cap) {
        return NULL;
    }
    void *np = realloc(ptr, nsize);
    if (np == NULL) {
        return NULL;
    }
    a->used = a->used - old + nsize;
    return np;
}

typedef struct {
    lua_State *L;
    EngAlloc alloc;
} EngSlot;

static EngSlot gStates[ENGINE_MAXSTATES];
static int gNStates = 0;

/* The engine's kernel libraries, vendored through the dependency lock. */
extern int luaopen_lpeg(lua_State *L);
extern int luaopen_cjson(lua_State *L);

/* AVX2 gate for the primitive palette: computed once, in this plain
 * translation unit (col.c is compiled -mavx2 and must not execute before
 * the check). Without AVX2 the col library simply is not opened and the
 * capability is never declared - negotiation doing its job. */
static int gColOk = 0;

/* View identity for col: a weak-keyed per-state registry map from the
 * view table to its packed identity, written at view creation. Invisible
 * to kernels, unforgeable, collision-free (panel ruling). */
#define ENGINE_COLVIEWS "machteld.colviews"

typedef struct {
    int poolNum;
    int64_t a, b;
} EngViewId;

static void
ColViewsInit(lua_State *S)
{
    lua_newtable(S);
    lua_createtable(S, 0, 1);
    lua_pushstring(S, "k");
    lua_setfield(S, -2, "__mode");
    lua_setmetatable(S, -2);
    lua_setfield(S, LUA_REGISTRYINDEX, ENGINE_COLVIEWS);
}

int
EngineViewIdentity(lua_State *S, int idx, int *poolNumOut,
                   int64_t *aOut, int64_t *bOut)
{
    idx = lua_absindex(S, idx);
    if (lua_getfield(S, LUA_REGISTRYINDEX, ENGINE_COLVIEWS) != LUA_TTABLE) {
        lua_pop(S, 1);
        return 0;
    }
    lua_pushvalue(S, idx);
    lua_rawget(S, -2);
    if (lua_type(S, -1) != LUA_TUSERDATA) {
        lua_pop(S, 2);
        return 0;
    }
    EngViewId *id = (EngViewId *)lua_touserdata(S, -1);
    *poolNumOut = id->poolNum;
    *aOut = id->a;
    *bOut = id->b;
    lua_pop(S, 2);
    return 1;
}

static lua_State *
NewMeteredState(EngAlloc *a)
{
    a->used = 0;
    a->cap = (size_t)ENGINE_STATE_CAP_MB * 1024 * 1024;
    lua_State *S = lua_newstate(EngAllocF, a, 2654435769u);
    if (S == NULL) {
        return NULL;
    }
    /* The cage: pure computation only. base/string/math/table plus the
     * character library and the two vendored kernel libraries; never io,
     * os, package, or debug. */
    luaL_requiref(S, LUA_GNAME, luaopen_base, 1);
    luaL_requiref(S, LUA_STRLIBNAME, luaopen_string, 1);
    luaL_requiref(S, LUA_MATHLIBNAME, luaopen_math, 1);
    luaL_requiref(S, LUA_TABLIBNAME, luaopen_table, 1);
    luaL_requiref(S, LUA_UTF8LIBNAME, luaopen_utf8, 1);
    luaL_requiref(S, "lpeg", luaopen_lpeg, 1);
    luaL_requiref(S, "cjson", luaopen_cjson, 1);
    lua_settop(S, 0);
    ColViewsInit(S);
    if (gColOk) {
        MachteldCol_Open(S);
    }
    return S;
}

static int
MsgHandler(lua_State *S)
{
    const char *m = lua_tostring(S, 1);
    if (m == NULL) {
        m = "(non-string error)";
    }
    luaL_traceback(S, S, m, 1);
    return 1;
}

/* ---------------- registries: kernels, pools, results ---------------- */

/* Kernels: a bounded table with least-recently-used eviction. The PHM
 * endurance spike (2026-08-23) found that a full table refused every
 * further definition - a wall the whole engine fell off at once. Now the
 * 257th distinct name evicts the least recently run kernel: its global is
 * cleared in every state, and its next run refuses as "no kernel" until
 * it is defined again. */
typedef struct {
    char name[64];
    uint64_t hash;
    int used;
    uint64_t lastUse;
} Kernel;
static Kernel gKernels[ENGINE_MAX_KERNELS];
static uint64_t gKernelClock = 0;
static uint64_t gKernelEvictions = 0;

typedef struct {
    int state;
    char key[64];
} ViewRef;

/* A pool is columns over an arena. String cells reference (off,len) spans
 * of the arena, which holds unescaped field bytes; integer and double
 * columns are native arrays. The lines loader is the one-column case. */
#define ENGINE_MAX_COLS 64

typedef struct {
    char name[64];
    char type;                       /* 'i', 'f', or 's' */
    int64_t *i;                      /* type 'i' */
    double *f;                       /* type 'f' */
    int64_t *off;                    /* type 's', span mode: starts */
    int64_t *len;                    /* type 's', span mode: lengths */
    /* Dictionary mode (0.14): the column is one int32 code per row plus
     * the distinct spans, numbered in first-appearance order; the span
     * arrays above are freed. Codes cost 4 bytes/row where spans cost
     * 16. Past ENGINE_DICT_LIMIT distinct values the dictionary is
     * discarded and the column stays in span mode - the cardinality
     * escape, explicit and visible in stats. */
    int32_t *code;
    int64_t *dictOff;
    int64_t *dictLen;
    int64_t dictN;                   /* > 0 means dictionary mode */
} PoolCol;

#define ENGINE_DICT_LIMIT 65536

/* The effective dictionary limit: ENGINE_DICT_LIMIT by contract. The
 * UNCONTRACTED bench escape MACHTELD_DICT_LIMIT (plan-machteld-014's
 * cliff instrument) is read once: a well-formed value in [1, 1048576]
 * applies (larger clamps down to 1048576); anything malformed or
 * below 1 is IGNORED and the default stands - never a silent
 * clamp-to-1 that would disable dictionaries. Ambient state must be
 * visible: stats always reports dict_limit. Loads run on the op
 * thread only, so the once-latch is race-free. */
static int64_t gDictLimit = 0;

static int64_t
DictLimit(void)
{
    if (gDictLimit == 0) {
        int64_t v = ENGINE_DICT_LIMIT;
        const char *e = getenv("MACHTELD_DICT_LIMIT");
        if (e != NULL && *e != '\0') {
            char *end = NULL;
            long long parsed = strtoll(e, &end, 10);
            if (end != NULL && *end == '\0' && parsed >= 1) {
                v = (parsed > 1048576) ? 1048576 : (int64_t)parsed;
            }
        }
        gDictLimit = v;
    }
    return gDictLimit;
}

typedef struct {
    int used;
    int64_t rows;
    int ncols;
    PoolCol cols[ENGINE_MAX_COLS];
    char *arena;
    size_t arenaLen;
    ViewRef *views;
    int nviews, capviews;
} Pool;
static Pool gPools[ENGINE_MAX_POOLS];
static int gPoolSeq = 0;

/* View tracking mutates the shared Pool struct, and the FIRST sharded run
 * over a fresh pool builds every shard's view concurrently - one worker
 * thread per state, all appending to the same views array. The lua_State
 * side is per-thread by law; this lock covers only the shared bookkeeping.
 * (Found by the 0.13.0 plan's adversarial review panel; a 0.12.0 defect.) */
static CRITICAL_SECTION gViewLock;

int
EnginePoolLive(int poolNum)
{
    for (int i = 0; i < ENGINE_MAX_POOLS; i++) {
        if (gPools[i].used == poolNum) {
            return 1;
        }
    }
    return 0;
}

char
EnginePoolStrColumn(int poolNum, const char *field, EngineStrCol *out)
{
    Pool *p = NULL;
    for (int i = 0; i < ENGINE_MAX_POOLS; i++) {
        if (gPools[i].used == poolNum) {
            p = &gPools[i];
            break;
        }
    }
    if (p == NULL) {
        return 0;
    }
    for (int c = 0; c < p->ncols; c++) {
        if (strcmp(p->cols[c].name, field) == 0) {
            PoolCol *col = &p->cols[c];
            if (col->type != 's') {
                return 'n';
            }
            out->arena = p->arena;
            out->rows = p->rows;
            out->code = col->code;
            out->dictOff = col->dictOff;
            out->dictLen = col->dictLen;
            out->dictN = col->dictN;
            out->off = col->off;
            out->len = col->len;
            return (col->dictN > 0) ? 'd' : 'p';
        }
    }
    return '?';
}

int
EnginePoolField(int poolNum, int idx, const char **nameOut, char *typeOut)
{
    Pool *p = NULL;
    for (int i = 0; i < ENGINE_MAX_POOLS; i++) {
        if (gPools[i].used == poolNum) {
            p = &gPools[i];
            break;
        }
    }
    if (p == NULL || idx < 0 || idx >= p->ncols) {
        return 0;
    }
    *nameOut = p->cols[idx].name;
    *typeOut = p->cols[idx].type;
    return 1;
}

int
EnginePoolColumn(int poolNum, const char *field, char *typeOut,
                 const void **dataOut, int64_t *rowsOut)
{
    Pool *p = NULL;
    for (int i = 0; i < ENGINE_MAX_POOLS; i++) {
        if (gPools[i].used == poolNum) {
            p = &gPools[i];
            break;
        }
    }
    if (p == NULL) {
        *typeOut = 0;                          /* the pool is gone */
        return 0;
    }
    for (int c = 0; c < p->ncols; c++) {
        if (strcmp(p->cols[c].name, field) == 0) {
            *typeOut = p->cols[c].type;
            *rowsOut = p->rows;
            switch (p->cols[c].type) {
            case 'i': *dataOut = p->cols[c].i; break;
            case 'f': *dataOut = p->cols[c].f; break;
            default:  *dataOut = NULL;
            }
            return 1;
        }
    }
    *typeOut = '?';                            /* live pool, unknown field */
    return 0;
}

typedef struct {
    int used;
    int ref;                         /* registry ref in state 0 */
} Result;
static Result gResults[ENGINE_MAX_RESULTS];
static int gResultSeq = 0;

/* ---------------- stats ---------------- */

static struct {
    uint64_t frames, bytesIn, bytesOut, runs, spills, viewEvictions;
    ULONGLONG t0;
} gStats;

static double
NowMs(void)
{
    static LARGE_INTEGER f;
    static int init = 0;
    LARGE_INTEGER c;
    if (!init) {
        QueryPerformanceFrequency(&f);
        init = 1;
    }
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
}

/* ---------------- frames ---------------- */

static char *
ReadFrame(size_t *outLen)
{
    unsigned char hdr[4];
    if (fread(hdr, 1, 4, stdin) != 4) {
        return NULL;
    }
    uint32_t len = (uint32_t)hdr[0] | ((uint32_t)hdr[1] << 8) |
                   ((uint32_t)hdr[2] << 16) | ((uint32_t)hdr[3] << 24);
    if (len > ENGINE_FRAME_MAX) {
        return NULL;
    }
    char *buf = (char *)malloc((size_t)len + 1);
    if (buf == NULL) {
        return NULL;
    }
    if (len != 0 && fread(buf, 1, len, stdin) != len) {
        free(buf);
        return NULL;
    }
    buf[len] = '\0';
    gStats.frames++;
    gStats.bytesIn += len + 4;
    *outLen = len;
    return buf;
}

static void
SendBuf(EjBuf *b)
{
    if (b->oom) {
        /* An out-of-memory reply cannot be built; the host observes the
         * dead pipe and reports MACHT died, which is the honest outcome. */
        exit(3);
    }
    uint32_t len = (uint32_t)b->len;
    unsigned char hdr[4] = {
        (unsigned char)(len & 255u), (unsigned char)((len >> 8) & 255u),
        (unsigned char)((len >> 16) & 255u), (unsigned char)((len >> 24) & 255u)
    };
    fwrite(hdr, 1, 4, stdout);
    fwrite(b->bytes, 1, b->len, stdout);
    fflush(stdout);
    gStats.bytesOut += len + 4;
    EjBufFree(b);
}

static void
SendError(int64_t id, const char *code, const char *message)
{
    EjBuf b;
    EjBufInit(&b);
    EjBufText(&b, "{\"id\":");
    EjBufInt(&b, id);
    EjBufText(&b, ",\"ok\":false,\"error\":{\"code\":");
    EjBufString(&b, code, strlen(code));
    EjBufText(&b, ",\"message\":");
    EjBufString(&b, message, strlen(message));
    EjBufText(&b, "}}");
    SendBuf(&b);
}

static void
OkOpen(EjBuf *b, int64_t id)
{
    EjBufInit(b);
    EjBufText(b, "{\"id\":");
    EjBufInt(b, id);
    EjBufText(b, ",\"ok\":true");
}

/* ---------------- UTF-8 validation ---------------- */

static int
Utf8Valid(const unsigned char *s, size_t n)
{
    size_t i = 0;
    while (i < n) {
        unsigned char c = s[i];
        if (c < 0x80) {
            i++;
        } else if ((c & 0xE0) == 0xC0) {
            if (i + 1 >= n || (s[i+1] & 0xC0) != 0x80 || c < 0xC2) {
                return 0;
            }
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            if (i + 2 >= n || (s[i+1] & 0xC0) != 0x80 ||
                    (s[i+2] & 0xC0) != 0x80 ||
                    (c == 0xE0 && s[i+1] < 0xA0) ||
                    (c == 0xED && s[i+1] >= 0xA0)) {
                return 0;
            }
            i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            if (i + 3 >= n || (s[i+1] & 0xC0) != 0x80 ||
                    (s[i+2] & 0xC0) != 0x80 || (s[i+3] & 0xC0) != 0x80 ||
                    (c == 0xF0 && s[i+1] < 0x90) || c > 0xF4 ||
                    (c == 0xF4 && s[i+1] >= 0x90)) {
                return 0;
            }
            i += 4;
        } else {
            return 0;
        }
    }
    return 1;
}

/* ---------------- pools and views ---------------- */

static Pool *
PoolByHandle(const char *h, int *numOut)
{
    int num = 0;
    if (sscanf(h, "pool#%d", &num) != 1) {
        return NULL;
    }
    for (int i = 0; i < ENGINE_MAX_POOLS; i++) {
        if (gPools[i].used && gPools[i].used == num) {
            if (numOut != NULL) {
                *numOut = num;
            }
            return &gPools[i];
        }
    }
    return NULL;
}

static void PoolTrackViewLocked(Pool *p, int state, const char *key);

/* The view cache is bounded: at most ENGINE_VIEWS_PER_STATE cached row
 * ranges per state per pool. The endurance spike found the unbounded
 * cache retaining every range a hot pool was ever sharded by (3x memory
 * at twelve variants). Eviction is oldest-first within THIS state - the
 * registry write is on the calling thread's own state, the shared list
 * under the lock - and only the cache reference goes: a kernel still
 * holding an evicted view keeps a valid, live table. */
#define ENGINE_VIEWS_PER_STATE 2

static void
PoolTrackView(lua_State *S, Pool *p, int state, const char *key)
{
    EnterCriticalSection(&gViewLock);
    PoolTrackViewLocked(p, state, key);
    int mine = 0;
    for (int i = 0; i < p->nviews; i++) {
        if (p->views[i].state == state) {
            mine++;
        }
    }
    while (mine > ENGINE_VIEWS_PER_STATE) {
        for (int i = 0; i < p->nviews; i++) {
            if (p->views[i].state == state) {
                lua_pushnil(S);
                lua_setfield(S, LUA_REGISTRYINDEX, p->views[i].key);
                memmove(&p->views[i], &p->views[i + 1],
                        (size_t)(p->nviews - i - 1) * sizeof(ViewRef));
                p->nviews--;
                gStats.viewEvictions++;
                break;
            }
        }
        mine--;
    }
    LeaveCriticalSection(&gViewLock);
}

static void
PoolTrackViewLocked(Pool *p, int state, const char *key)
{
    if (p->nviews == p->capviews) {
        int cap = (p->capviews == 0) ? 8 : p->capviews * 2;
        ViewRef *nv = (ViewRef *)realloc(p->views,
                                         (size_t)cap * sizeof(ViewRef));
        if (nv == NULL) {
            return;                  /* view stays uncached-on-free: leak
                                      * bounded by state lifetime */
        }
        p->views = nv;
        p->capviews = cap;
    }
    p->views[p->nviews].state = state;
    snprintf(p->views[p->nviews].key, sizeof(p->views[p->nviews].key),
             "%s", key);
    p->nviews++;
}

/* Build one column of the view [a,b) as a Lua sequence - the same bytes
 * whether the column is dictionary- or span-mode. Leaves it on top. */
static void
PushColumnTable(lua_State *S, Pool *p, PoolCol *col, int64_t a, int64_t b)
{
    int64_t n = b - a;
    lua_createtable(S, (int)n, 0);
    for (int64_t i = 0; i < n; i++) {
        switch (col->type) {
        case 'i':
            lua_pushinteger(S, (lua_Integer)col->i[a + i]);
            break;
        case 'f':
            lua_pushnumber(S, (lua_Number)col->f[a + i]);
            break;
        default:
            if (col->dictN > 0) {
                int32_t dc = col->code[a + i];
                lua_pushlstring(S, p->arena + col->dictOff[dc],
                                (size_t)col->dictLen[dc]);
            } else {
                lua_pushlstring(S, p->arena + col->off[a + i],
                                (size_t)col->len[a + i]);
            }
        }
        lua_rawseti(S, -2, (lua_Integer)(i + 1));
    }
}

/* The lazy view's __index (0.14): materialize the touched column and
 * rawset it, so the metamethod never fires again for that name and the
 * kernel's loop runs on a plain table. THE LIVENESS LAW (panel blocker,
 * plan-machteld-014): resolve the pool by its MONOTONE NUMBER at every
 * touch, cache no Pool/arena/column pointer anywhere; a stashed view
 * whose pool was freed refuses by name on its first untouched column
 * instead of reading freed memory. Already-materialized columns keep
 * working - the eager guarantee, narrowed honestly. Concurrency: this
 * mutates only the calling state's own table and reads only the
 * read-only-after-load pool; the shared view bookkeeping ran once at
 * view creation - no shared state is touched here. */
#define ENGINE_LAZYMETA "machteld.lazyview"

static int
ViewIndex(lua_State *S)
{
    if (lua_type(S, 2) != LUA_TSTRING) {
        lua_pushnil(S);
        return 1;
    }
    int poolNum;
    int64_t a, b;
    if (!EngineViewIdentity(S, 1, &poolNum, &a, &b)) {
        lua_pushnil(S);                /* not a tracked view: plain miss */
        return 1;
    }
    Pool *p = NULL;
    for (int i = 0; i < ENGINE_MAX_POOLS; i++) {
        if (gPools[i].used == poolNum) {
            p = &gPools[i];
            break;
        }
    }
    if (p == NULL) {
        return luaL_error(S, "col: view outlives its pool");
    }
    const char *name = lua_tostring(S, 2);
    for (int c = 0; c < p->ncols; c++) {
        if (strcmp(p->cols[c].name, name) == 0) {
            PushColumnTable(S, p, &p->cols[c], a, b);
            lua_pushvalue(S, 2);
            lua_pushvalue(S, -2);
            lua_rawset(S, 1);          /* h[name] = the column, once */
            return 1;
        }
    }
    lua_pushnil(S);
    return 1;
}

/* Push the pool view [a,b) as the kernel-visible object: h.rows eagerly,
 * every column lazily through ViewIndex (a col-only kernel over a pool
 * of any size touches no column and allocates almost nothing). Cached
 * per (state, range) in that state's registry. */
static void
PushPoolView(lua_State *S, int stateIdx, Pool *p, int poolNum,
             int64_t a, int64_t b)
{
    char key[64];
    snprintf(key, sizeof(key), "mv:%d:%lld:%lld", poolNum,
             (long long)a, (long long)b);
    if (lua_getfield(S, LUA_REGISTRYINDEX, key) == LUA_TTABLE) {
        return;                                    /* cache hit */
    }
    lua_pop(S, 1);
    int64_t n = b - a;
    lua_createtable(S, 0, p->ncols + 1);
    lua_pushinteger(S, (lua_Integer)n);
    lua_setfield(S, -2, "rows");
    if (lua_getfield(S, LUA_REGISTRYINDEX, ENGINE_LAZYMETA) != LUA_TTABLE) {
        lua_pop(S, 1);
        lua_createtable(S, 0, 2);
        lua_pushcfunction(S, ViewIndex);
        lua_setfield(S, -2, "__index");
        lua_pushliteral(S, "machteld view");
        lua_setfield(S, -2, "__metatable");
        lua_pushvalue(S, -1);
        lua_setfield(S, LUA_REGISTRYINDEX, ENGINE_LAZYMETA);
    }
    lua_setmetatable(S, -2);
    lua_pushvalue(S, -1);
    lua_setfield(S, LUA_REGISTRYINDEX, key);
    PoolTrackView(S, p, stateIdx, key);
    /* Record the view's identity for col, invisibly (weak-keyed). */
    if (lua_getfield(S, LUA_REGISTRYINDEX, ENGINE_COLVIEWS) == LUA_TTABLE) {
        lua_pushvalue(S, -2);                  /* the view table as key */
        EngViewId *id = (EngViewId *)lua_newuserdatauv(S,
            sizeof(EngViewId), 0);
        id->poolNum = poolNum;
        id->a = a;
        id->b = b;
        lua_rawset(S, -3);
    }
    lua_pop(S, 1);
}

static void
PoolFree(Pool *p)
{
    for (int i = 0; i < p->nviews; i++) {
        lua_State *S = gStates[p->views[i].state].L;
        lua_pushnil(S);
        lua_setfield(S, LUA_REGISTRYINDEX, p->views[i].key);
    }
    free(p->views);
    for (int c = 0; c < p->ncols; c++) {
        free(p->cols[c].i);
        free(p->cols[c].f);
        free(p->cols[c].off);
        free(p->cols[c].len);
        free(p->cols[c].code);
        free(p->cols[c].dictOff);
        free(p->cols[c].dictLen);
    }
    free(p->arena);
    memset(p, 0, sizeof(*p));
}

/* Build the dictionary for one span-mode s column: open-addressed hash
 * over the arena spans, first-appearance numbering. On success the span
 * arrays are freed and the column flips to dictionary mode; past the
 * limit everything is discarded and the column stays as it was. */
static void
PoolDictBuild(Pool *p, PoolCol *col)
{
    int64_t rows = p->rows;
    if (rows == 0) {
        return;
    }
    int64_t limit = DictLimit();
    size_t htSize = 4;
    while (htSize < (size_t)limit * 4) {
        htSize <<= 1;
    }
    int32_t *ht = (int32_t *)malloc(htSize * sizeof(int32_t));
    int32_t *code = (int32_t *)malloc((size_t)rows * sizeof(int32_t));
    int64_t *dOff = (int64_t *)malloc((size_t)limit * sizeof(int64_t));
    int64_t *dLen = (int64_t *)malloc((size_t)limit * sizeof(int64_t));
    if (ht == NULL || code == NULL || dOff == NULL || dLen == NULL) {
        free(ht);
        free(code);
        free(dOff);
        free(dLen);
        return;                                    /* stay in span mode */
    }
    memset(ht, 0xFF, htSize * sizeof(int32_t));    /* -1 = empty */
    int64_t dictN = 0;
    for (int64_t r = 0; r < rows; r++) {
        const char *s = p->arena + col->off[r];
        int64_t n = col->len[r];
        uint64_t h = 1469598103934665603ull;
        for (int64_t k = 0; k < n; k++) {
            h ^= (unsigned char)s[k];
            h *= 1099511628211ull;
        }
        size_t slot = (size_t)h & (htSize - 1);
        for (;;) {
            int32_t idx = ht[slot];
            if (idx < 0) {
                if (dictN == limit) {
                    free(ht);
                    free(code);
                    free(dOff);
                    free(dLen);
                    return;                        /* the escape: span mode */
                }
                ht[slot] = (int32_t)dictN;
                dOff[dictN] = col->off[r];
                dLen[dictN] = n;
                code[r] = (int32_t)dictN;
                dictN++;
                break;
            }
            if (dLen[idx] == n &&
                    memcmp(p->arena + dOff[idx], s, (size_t)n) == 0) {
                code[r] = idx;
                break;
            }
            slot = (slot + 1) & (htSize - 1);
        }
    }
    free(ht);
    /* Shrink the dictionary arrays from the limit to what they hold;
     * on a refused shrink the full-size originals stay valid. */
    int64_t *t = (int64_t *)realloc(dOff, (size_t)dictN * sizeof(int64_t));
    if (t != NULL) {
        dOff = t;
    }
    t = (int64_t *)realloc(dLen, (size_t)dictN * sizeof(int64_t));
    if (t != NULL) {
        dLen = t;
    }
    free(col->off);
    free(col->len);
    col->off = NULL;
    col->len = NULL;
    col->code = code;
    col->dictOff = dOff;
    col->dictLen = dLen;
    col->dictN = dictN;
}

/* ---------------- Ej -> Lua and Lua -> JSON conversion ---------------- */

typedef struct {
    char msg[256];
} ConvErr;

/* Push an Ej value into S. Handles are resolved only at argument top level
 * by the caller; nested {"handle":...} is a type error. {"float":"nan"} is
 * honored at any depth per the boundary's tagged-float law. */
static int
EjToLua(lua_State *S, const Ej *v, int depth, ConvErr *e)
{
    if (depth > ENGINE_CONV_DEPTH) {
        snprintf(e->msg, sizeof(e->msg), "value nesting exceeds %d",
                 ENGINE_CONV_DEPTH);
        return 0;
    }
    if (!lua_checkstack(S, 4)) {
        snprintf(e->msg, sizeof(e->msg), "lua stack exhausted");
        return 0;
    }
    switch (v->kind) {
    case EJ_NULL:
        snprintf(e->msg, sizeof(e->msg), "null cannot cross as an argument");
        return 0;
    case EJ_TRUE:
        lua_pushboolean(S, 1);
        return 1;
    case EJ_FALSE:
        lua_pushboolean(S, 0);
        return 1;
    case EJ_INT:
        lua_pushinteger(S, (lua_Integer)v->u.i);
        return 1;
    case EJ_DOUBLE:
        lua_pushnumber(S, (lua_Number)v->u.d);
        return 1;
    case EJ_STRING:
        lua_pushlstring(S, v->u.s.bytes, v->u.s.len);
        return 1;
    case EJ_ARRAY:
        lua_createtable(S, (int)v->u.a.count, 0);
        for (size_t i = 0; i < v->u.a.count; i++) {
            if (!EjToLua(S, v->u.a.items[i], depth + 1, e)) {
                return 0;
            }
            lua_rawseti(S, -2, (lua_Integer)(i + 1));
        }
        return 1;
    case EJ_OBJECT: {
        Ej *f = EjGet(v, "float");
        if (f != NULL && v->u.a.count == 1 && f->kind == EJ_STRING) {
            if (strcmp(f->u.s.bytes, "nan") == 0) {
                lua_pushnumber(S, (lua_Number)NAN);
                return 1;
            }
            if (strcmp(f->u.s.bytes, "inf") == 0) {
                lua_pushnumber(S, (lua_Number)INFINITY);
                return 1;
            }
            if (strcmp(f->u.s.bytes, "-inf") == 0) {
                lua_pushnumber(S, -(lua_Number)INFINITY);
                return 1;
            }
        }
        if (EjGet(v, "handle") != NULL) {
            snprintf(e->msg, sizeof(e->msg),
                     "a handle is only legal as a top-level argument");
            return 0;
        }
        lua_createtable(S, 0, (int)v->u.a.count);
        for (size_t i = 0; i < v->u.a.count; i++) {
            Ej *k = v->u.a.items[i * 2];
            lua_pushlstring(S, k->u.s.bytes, k->u.s.len);
            if (!EjToLua(S, v->u.a.items[i * 2 + 1], depth + 1, e)) {
                return 0;
            }
            lua_rawset(S, -3);
        }
        return 1;
    }
    }
    snprintf(e->msg, sizeof(e->msg), "unreachable value kind");
    return 0;
}

/* Encode the Lua value at idx as JSON per the boundary's edge laws:
 * nil-in-container is a type error; strings must be UTF-8; a table is a
 * 1..n sequence (array) or a string-keyed map (object), never mixed;
 * non-finite floats leave as the tagged object. */
static int
LuaToJson(lua_State *S, int idx, EjBuf *out, int depth, int topLevel,
          ConvErr *e)
{
    if (depth > ENGINE_CONV_DEPTH) {
        snprintf(e->msg, sizeof(e->msg), "result nesting exceeds %d",
                 ENGINE_CONV_DEPTH);
        return 0;
    }
    if (!lua_checkstack(S, 6)) {
        snprintf(e->msg, sizeof(e->msg), "lua stack exhausted");
        return 0;
    }
    idx = lua_absindex(S, idx);
    switch (lua_type(S, idx)) {
    case LUA_TNIL:
        if (!topLevel) {
            snprintf(e->msg, sizeof(e->msg), "nil inside a container");
            return 0;
        }
        EjBufText(out, "null");
        return 1;
    case LUA_TBOOLEAN:
        EjBufText(out, lua_toboolean(S, idx) ? "true" : "false");
        return 1;
    case LUA_TNUMBER:
        if (lua_isinteger(S, idx)) {
            EjBufInt(out, (int64_t)lua_tointeger(S, idx));
        } else {
            double d = (double)lua_tonumber(S, idx);
            if (!isfinite(d)) {
                if (isnan(d)) {
                    EjBufText(out, "{\"float\":\"nan\"}");
                } else if (d > 0) {
                    EjBufText(out, "{\"float\":\"inf\"}");
                } else {
                    EjBufText(out, "{\"float\":\"-inf\"}");
                }
            } else {
                EjBufDouble(out, d);
            }
        }
        return 1;
    case LUA_TSTRING: {
        size_t n;
        const char *s = lua_tolstring(S, idx, &n);
        if (!Utf8Valid((const unsigned char *)s, n)) {
            snprintf(e->msg, sizeof(e->msg),
                     "string is not valid UTF-8 (binary stays in the engine)");
            return 0;
        }
        EjBufString(out, s, n);
        return 1;
    }
    case LUA_TTABLE: {
        /* Classify: count pairs; all-integer keys 1..T = array, all-string
         * keys = object, anything else = type error. */
        int64_t pairs = 0;
        int allInt = 1, allStr = 1;
        int64_t maxk = 0;
        lua_pushnil(S);
        while (lua_next(S, idx) != 0) {
            pairs++;
            if (lua_isinteger(S, -2)) {
                allStr = 0;
                int64_t k = (int64_t)lua_tointeger(S, -2);
                if (k < 1) {
                    allInt = 0;
                }
                if (k > maxk) {
                    maxk = k;
                }
            } else if (lua_type(S, -2) == LUA_TSTRING) {
                allInt = 0;
            } else {
                allInt = 0;
                allStr = 0;
            }
            lua_pop(S, 1);
        }
        if (pairs == 0) {
            EjBufText(out, "[]");
            return 1;
        }
        if (allInt && maxk == pairs) {
            EjBufText(out, "[");
            for (int64_t i = 1; i <= pairs; i++) {
                if (i > 1) {
                    EjBufText(out, ",");
                }
                lua_rawgeti(S, idx, (lua_Integer)i);
                int ok = LuaToJson(S, -1, out, depth + 1, 0, e);
                lua_pop(S, 1);
                if (!ok) {
                    return 0;
                }
            }
            EjBufText(out, "]");
            return 1;
        }
        if (allInt) {
            snprintf(e->msg, sizeof(e->msg),
                     "nil inside a container (sequence has holes)");
            return 0;
        }
        if (!allStr) {
            snprintf(e->msg, sizeof(e->msg),
                     "table mixes integer and string keys");
            return 0;
        }
        EjBufText(out, "{");
        int first = 1;
        lua_pushnil(S);
        while (lua_next(S, idx) != 0) {
            size_t kn;
            const char *ks = lua_tolstring(S, -2, &kn);
            if (!Utf8Valid((const unsigned char *)ks, kn)) {
                lua_pop(S, 2);
                snprintf(e->msg, sizeof(e->msg), "key is not valid UTF-8");
                return 0;
            }
            if (!first) {
                EjBufText(out, ",");
            }
            first = 0;
            EjBufString(out, ks, kn);
            EjBufText(out, ":");
            if (!LuaToJson(S, -1, out, depth + 1, 0, e)) {
                lua_pop(S, 2);
                return 0;
            }
            lua_pop(S, 1);
        }
        EjBufText(out, "}");
        return 1;
    }
    default:
        snprintf(e->msg, sizeof(e->msg),
                 "a %s cannot cross the boundary", luaL_typename(S, idx));
        return 0;
    }
}

/* ---------------- kernels ---------------- */

static uint64_t
Fnv1a(const char *s, size_t n)
{
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) {
        h ^= (unsigned char)s[i];
        h *= 1099511628211ull;
    }
    return h;
}

static int
NameOk(const char *s, size_t n)
{
    if (n == 0 || n >= 64) {
        return 0;
    }
    if (!((s[0] >= 'a' && s[0] <= 'z') || (s[0] >= 'A' && s[0] <= 'Z') ||
            s[0] == '_')) {
        return 0;
    }
    for (size_t i = 1; i < n; i++) {
        char c = s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                (c >= '0' && c <= '9') || c == '_')) {
            return 0;
        }
    }
    return 1;
}

static Kernel *
KernelFind(const char *name)
{
    for (int i = 0; i < ENGINE_MAX_KERNELS; i++) {
        if (gKernels[i].used && strcmp(gKernels[i].name, name) == 0) {
            return &gKernels[i];
        }
    }
    return NULL;
}

/* ---------------- ops ---------------- */

static int gHelloDone = 0;

static void
OpHello(int64_t id, const Ej *req)
{
    Ej *proto = EjGet(req, "protocol");
    if (proto == NULL || proto->kind != EJ_INT ||
            proto->u.i != ENGINE_PROTOCOL) {
        SendError(id, "protocol", "this engine speaks protocol 1 only");
        return;
    }
    gHelloDone = 1;
    EjBuf b;
    OkOpen(&b, id);
    EjBufText(&b, ",\"engine\":\"machteld\",\"version\":\"");
    EjBufText(&b, MACHTELD_VERSION);
    EjBufText(&b, "\",\"protocol\":1,\"capabilities\":"
        "[\"lua\",\"load.lines\",\"load.csv\",\"shards\",\"reduce\","
        "\"stats\"");
    if (gColOk) {
        EjBufText(&b, ",\"col\"");
    }
    EjBufText(&b, "]}");
    SendBuf(&b);
}

/* ---- load plumbing: file reading, growable arena, cell recorder ---- */

typedef struct {
    char *p;
    size_t len, cap;
} Grow;

static int
GrowBytes(Grow *g, const char *s, size_t n)
{
    if (g->len + n > g->cap) {
        size_t cap = (g->cap == 0) ? 4096 : g->cap;
        while (cap < g->len + n) {
            cap *= 2;
        }
        char *np = (char *)realloc(g->p, cap);
        if (np == NULL) {
            return 0;
        }
        g->p = np;
        g->cap = cap;
    }
    memcpy(g->p + g->len, s, n);
    g->len += n;
    return 1;
}

typedef struct {
    int64_t *v;
    size_t n, cap;
} I64Vec;

static int
I64Push(I64Vec *v, int64_t x)
{
    if (v->n == v->cap) {
        size_t cap = (v->cap == 0) ? 256 : v->cap * 2;
        int64_t *np = (int64_t *)realloc(v->v, cap * sizeof(int64_t));
        if (np == NULL) {
            return 0;
        }
        v->v = np;
        v->cap = cap;
    }
    v->v[v->n++] = x;
    return 1;
}

/* Row-major parse product: unescaped field bytes in an arena, one (off,len)
 * pair per cell, the source line of each record for honest type errors. */
typedef struct {
    Grow arena;
    I64Vec off, len, lineOf;
    int64_t records;
    int ncols;
    char err[256];
} Parsed;

static void
ParsedFree(Parsed *ps)
{
    free(ps->arena.p);
    free(ps->off.v);
    free(ps->len.v);
    free(ps->lineOf.v);
    memset(ps, 0, sizeof(*ps));
}

static char *
ReadWholeFile(const char *pathUtf8, long long *sizeOut, const char **errOut)
{
    int wlen = MultiByteToWideChar(CP_UTF8, 0, pathUtf8, -1, NULL, 0);
    WCHAR *wpath = (WCHAR *)malloc((size_t)(wlen > 0 ? wlen : 1) *
                                   sizeof(WCHAR));
    if (wpath == NULL || wlen == 0) {
        free(wpath);
        *errOut = "path conversion failed";
        return NULL;
    }
    MultiByteToWideChar(CP_UTF8, 0, pathUtf8, -1, wpath, wlen);
    FILE *fh = _wfopen(wpath, L"rb");
    free(wpath);
    if (fh == NULL) {
        *errOut = "cannot open the path for reading";
        return NULL;
    }
    _fseeki64(fh, 0, SEEK_END);
    long long size = _ftelli64(fh);
    _fseeki64(fh, 0, SEEK_SET);
    if (size < 0) {
        fclose(fh);
        *errOut = "cannot size the file";
        return NULL;
    }
    char *bytes = (char *)malloc((size_t)size + 1);
    if (bytes == NULL) {
        fclose(fh);
        *errOut = "file does not fit in engine memory";
        return NULL;
    }
    if (size > 0 && fread(bytes, 1, (size_t)size, fh) != (size_t)size) {
        free(bytes);
        fclose(fh);
        *errOut = "short read";
        return NULL;
    }
    fclose(fh);
    bytes[size] = '\0';
    *sizeOut = size;
    return bytes;
}

static int
CellCommit(Parsed *ps, size_t start)
{
    return I64Push(&ps->off, (int64_t)start) &&
           I64Push(&ps->len, (int64_t)(ps->arena.len - start));
}

/* The lines parser: one 's' column, CRLF and LF, empty lines are rows, a
 * final unterminated line is a row. */
static int
LinesParse(const char *bytes, long long size, Parsed *ps)
{
    ps->ncols = 1;
    long long start = 0;
    int64_t line = 1;
    for (long long i = 0; i <= size; i++) {
        if (i == size || bytes[i] == '\n') {
            if (i == size && start == i) {
                break;
            }
            long long end = i;
            if (end > start && bytes[end - 1] == '\r') {
                end--;
            }
            size_t a = ps->arena.len;
            if (!GrowBytes(&ps->arena, bytes + start, (size_t)(end - start)) ||
                    !CellCommit(ps, a) || !I64Push(&ps->lineOf, line)) {
                snprintf(ps->err, sizeof(ps->err), "out of memory");
                return 0;
            }
            ps->records++;
            line++;
            start = i + 1;
        }
    }
    return 1;
}

/* The csv parser: strict RFC 4180. Quoted fields with doubled quotes and
 * embedded newlines; CRLF and LF record ends; a quote in an unquoted
 * field, data after a closing quote, a bare CR, an unterminated quote,
 * and a ragged record are each refused naming their line. */
static int
CsvParse(const char *bytes, long long size, Parsed *ps)
{
    long long i = 0;
    int64_t line = 1, recLine = 1;
    int fieldsInRec = 0;
    while (i <= size) {
        /* One field, starting here. */
        size_t a = ps->arena.len;
        if (i < size && bytes[i] == '"') {
            i++;
            for (;;) {
                if (i >= size) {
                    snprintf(ps->err, sizeof(ps->err),
                             "line %lld: unterminated quoted field",
                             (long long)recLine);
                    return 0;
                }
                char c = bytes[i];
                if (c == '"') {
                    if (i + 1 < size && bytes[i + 1] == '"') {
                        if (!GrowBytes(&ps->arena, "\"", 1)) {
                            goto oom;
                        }
                        i += 2;
                        continue;
                    }
                    i++;
                    break;                          /* closing quote */
                }
                if (c == '\n') {
                    line++;
                }
                if (!GrowBytes(&ps->arena, &c, 1)) {
                    goto oom;
                }
                i++;
            }
            if (i < size && bytes[i] != ',' && bytes[i] != '\n' &&
                    !(bytes[i] == '\r' && i + 1 < size &&
                      bytes[i + 1] == '\n')) {
                snprintf(ps->err, sizeof(ps->err),
                         "line %lld: data after closing quote",
                         (long long)line);
                return 0;
            }
        } else {
            while (i < size && bytes[i] != ',' && bytes[i] != '\n' &&
                    bytes[i] != '\r') {
                if (bytes[i] == '"') {
                    snprintf(ps->err, sizeof(ps->err),
                             "line %lld: quote in unquoted field",
                             (long long)line);
                    return 0;
                }
                if (!GrowBytes(&ps->arena, &bytes[i], 1)) {
                    goto oom;
                }
                i++;
            }
            if (i < size && bytes[i] == '\r' &&
                    !(i + 1 < size && bytes[i + 1] == '\n')) {
                snprintf(ps->err, sizeof(ps->err),
                         "line %lld: bare carriage return",
                         (long long)line);
                return 0;
            }
        }
        if (!CellCommit(ps, a)) {
            goto oom;
        }
        fieldsInRec++;
        /* Delimiter, record end, or EOF. */
        if (i < size && bytes[i] == ',') {
            i++;
            continue;
        }
        int atEof = (i >= size);
        if (!atEof) {
            if (bytes[i] == '\r') {
                i++;                                /* the LF is next */
            }
            i++;                                    /* the LF */
            line++;
        }
        /* Commit the record unless it is the empty tail after a final
         * newline (one empty field born from EOF). */
        if (atEof && fieldsInRec == 1 &&
                ps->len.v[ps->len.n - 1] == 0 &&
                (ps->records > 0 || size == 0)) {
            long long lastEnd = size;
            if (lastEnd == 0 || bytes[lastEnd - 1] == '\n') {
                ps->off.n--;
                ps->len.n--;
                break;
            }
        }
        if (ps->ncols == 0) {
            if (fieldsInRec > ENGINE_MAX_COLS) {
                snprintf(ps->err, sizeof(ps->err),
                         "line %lld: %d fields exceeds the %d-column bound",
                         (long long)recLine, fieldsInRec, ENGINE_MAX_COLS);
                return 0;
            }
            ps->ncols = fieldsInRec;
        } else if (fieldsInRec != ps->ncols) {
            snprintf(ps->err, sizeof(ps->err),
                     "line %lld: %d fields where the first record has %d",
                     (long long)recLine, fieldsInRec, ps->ncols);
            return 0;
        }
        if (!I64Push(&ps->lineOf, recLine)) {
            goto oom;
        }
        ps->records++;
        fieldsInRec = 0;
        recLine = line;
        if (atEof) {
            break;
        }
        if (i >= size) {
            break;                                  /* file ended at newline */
        }
    }
    return 1;
oom:
    snprintf(ps->err, sizeof(ps->err), "out of memory");
    return 0;
}

/* Parse one cell span under a column type, exactly: the whole span, no
 * surrounding whitespace, or a refusal naming the record's line. */
static int
CellToI64(const char *s, int64_t n, int64_t *out)
{
    char buf[32];
    if (n <= 0 || n >= (int64_t)sizeof(buf)) {
        return 0;
    }
    memcpy(buf, s, (size_t)n);
    buf[n] = '\0';
    errno = 0;
    char *end = NULL;
    long long v = strtoll(buf, &end, 10);
    if (errno == ERANGE || end != buf + n) {
        return 0;
    }
    *out = (int64_t)v;
    return 1;
}

static int
CellToF64(const char *s, int64_t n, double *out)
{
    char buf[64];
    if (n <= 0 || n >= (int64_t)sizeof(buf)) {
        return 0;
    }
    memcpy(buf, s, (size_t)n);
    buf[n] = '\0';
    char *end = NULL;
    double v = strtod(buf, &end);
    if (end != buf + n) {
        return 0;
    }
    *out = v;
    return 1;
}

static void
OpLoad(int64_t id, const Ej *req)
{
    Ej *fmt = EjGet(req, "format");
    Ej *path = EjGet(req, "path");
    Ej *schemaE = EjGet(req, "schema");
    Ej *headerE = EjGet(req, "header");
    if (fmt == NULL || fmt->kind != EJ_STRING || path == NULL ||
            path->kind != EJ_STRING) {
        SendError(id, "usage", "load expects string format and path");
        return;
    }
    int isCsv = (strcmp(fmt->u.s.bytes, "csv") == 0);
    if (!isCsv && strcmp(fmt->u.s.bytes, "lines") != 0) {
        SendError(id, "refused", "this engine loads formats \"lines\" and "
                  "\"csv\"");
        return;
    }
    /* Tcl has no booleans, so hosts send 1; JSON-native hosts send true. */
    int header = (headerE != NULL && (headerE->kind == EJ_TRUE ||
                  (headerE->kind == EJ_INT && headerE->u.i != 0)));
    if (schemaE != NULL && (schemaE->kind != EJ_ARRAY ||
            schemaE->u.a.count % 2 != 0)) {
        SendError(id, "usage", "schema is pairs of field name and type");
        return;
    }

    const char *ferr = NULL;
    long long size = 0;
    char *bytes = ReadWholeFile(path->u.s.bytes, &size, &ferr);
    if (bytes == NULL) {
        SendError(id, strcmp(ferr, "file does not fit in engine memory") == 0
                  ? "memory" : "badvalue", ferr);
        return;
    }
    Parsed ps;
    memset(&ps, 0, sizeof(ps));
    int okParse = isCsv ? CsvParse(bytes, size, &ps)
                        : LinesParse(bytes, size, &ps);
    free(bytes);
    if (!okParse) {
        char msg[320];
        snprintf(msg, sizeof(msg), "%s: %s", isCsv ? "csv" : "lines", ps.err);
        const char *code = strcmp(ps.err, "out of memory") == 0 ? "memory"
                                                                : "badvalue";
        ParsedFree(&ps);
        SendError(id, code, msg);
        return;
    }
    if (isCsv && ps.records == 0) {
        ParsedFree(&ps);
        SendError(id, "badvalue", "csv: the file holds no records");
        return;
    }

    /* Resolve names and types: schema wins; a header names (and is
     * consumed); otherwise c1..cN, all strings. */
    int ncols = (ps.ncols > 0) ? ps.ncols : 1;
    char names[ENGINE_MAX_COLS][64];
    char types[ENGINE_MAX_COLS];
    for (int c = 0; c < ncols; c++) {
        snprintf(names[c], sizeof(names[c]), "c%d", c + 1);
        types[c] = 's';
    }
    if (!isCsv) {
        snprintf(names[0], sizeof(names[0]), "line");
    }
    int64_t firstRow = 0;
    if (isCsv && header) {
        if (ps.records < 1) {
            ParsedFree(&ps);
            SendError(id, "badvalue", "csv: -header with no header record");
            return;
        }
        for (int c = 0; c < ncols; c++) {
            int64_t off = ps.off.v[c], len = ps.len.v[c];
            if (len > 0 && len < 64) {
                memcpy(names[c], ps.arena.p + off, (size_t)len);
                names[c][len] = '\0';
            }
        }
        firstRow = 1;
    }
    if (isCsv && schemaE != NULL) {
        if ((int)(schemaE->u.a.count / 2) != ncols) {
            char msg[160];
            snprintf(msg, sizeof(msg),
                     "schema names %d columns, the file has %d",
                     (int)(schemaE->u.a.count / 2), ncols);
            ParsedFree(&ps);
            SendError(id, "badvalue", msg);
            return;
        }
        for (int c = 0; c < ncols; c++) {
            Ej *nm = schemaE->u.a.items[c * 2];
            Ej *ty = schemaE->u.a.items[c * 2 + 1];
            if (nm->kind != EJ_STRING || ty->kind != EJ_STRING ||
                    ty->u.s.len != 1 || (ty->u.s.bytes[0] != 'i' &&
                    ty->u.s.bytes[0] != 'f' && ty->u.s.bytes[0] != 's')) {
                ParsedFree(&ps);
                SendError(id, "usage",
                          "schema types are i, f, or s; names are strings");
                return;
            }
            snprintf(names[c], sizeof(names[c]), "%s", nm->u.s.bytes);
            types[c] = ty->u.s.bytes[0];
        }
    }
    for (int c = 0; c < ncols; c++) {
        for (int d = c + 1; d < ncols; d++) {
            if (strcmp(names[c], names[d]) == 0) {
                char msg[128];
                snprintf(msg, sizeof(msg), "duplicate column name %.63s",
                         names[c]);
                ParsedFree(&ps);
                SendError(id, "badvalue", msg);
                return;
            }
        }
    }

    int64_t rows = ps.records - firstRow;
    int slot = -1;
    for (int i = 0; i < ENGINE_MAX_POOLS; i++) {
        if (!gPools[i].used) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        ParsedFree(&ps);
        SendError(id, "badvalue", "too many pools (free some)");
        return;
    }
    Pool *p = &gPools[slot];
    memset(p, 0, sizeof(*p));
    p->rows = rows;
    p->ncols = ncols;
    size_t alloc = (size_t)(rows > 0 ? rows : 1);
    for (int c = 0; c < ncols; c++) {
        PoolCol *col = &p->cols[c];
        snprintf(col->name, sizeof(col->name), "%s", names[c]);
        col->type = types[c];
        int okAlloc = 1;
        if (types[c] == 'i') {
            okAlloc = (col->i = (int64_t *)malloc(alloc * 8)) != NULL;
        } else if (types[c] == 'f') {
            okAlloc = (col->f = (double *)malloc(alloc * 8)) != NULL;
        } else {
            col->off = (int64_t *)malloc(alloc * 8);
            col->len = (int64_t *)malloc(alloc * 8);
            okAlloc = col->off != NULL && col->len != NULL;
        }
        if (!okAlloc) {
            PoolFree(p);
            ParsedFree(&ps);
            SendError(id, "memory", "columns do not fit in engine memory");
            return;
        }
    }
    for (int64_t r = 0; r < rows; r++) {
        int64_t cell = (firstRow + r) * ncols;
        for (int c = 0; c < ncols; c++) {
            PoolCol *col = &p->cols[c];
            int64_t off = ps.off.v[cell + c], len = ps.len.v[cell + c];
            int okCell = 1;
            if (col->type == 'i') {
                okCell = CellToI64(ps.arena.p + off, len, &col->i[r]);
            } else if (col->type == 'f') {
                okCell = CellToF64(ps.arena.p + off, len, &col->f[r]);
            } else {
                col->off[r] = off;
                col->len[r] = len;
            }
            if (!okCell) {
                char msg[224];
                snprintf(msg, sizeof(msg),
                         "line %lld: field %s does not parse as %c",
                         (long long)ps.lineOf.v[firstRow + r], col->name,
                         col->type);
                PoolFree(p);
                ParsedFree(&ps);
                SendError(id, "badvalue", msg);
                return;
            }
        }
    }
    /* The pool adopts the arena; the index vectors die with Parsed. */
    p->arena = ps.arena.p;
    p->arenaLen = ps.arena.len;
    ps.arena.p = NULL;
    ParsedFree(&ps);
    /* Dictionary-encode the string columns (0.14). "dict":0 in the
     * request skips it - a bench-lane escape for measuring the toll,
     * not a contracted option. */
    Ej *dictE = EjGet(req, "dict");
    if (!(dictE != NULL && dictE->kind == EJ_INT && dictE->u.i == 0)) {
        for (int c = 0; c < ncols; c++) {
            if (p->cols[c].type == 's') {
                PoolDictBuild(p, &p->cols[c]);
            }
        }
    }
    p->used = ++gPoolSeq;

    EjBuf b;
    OkOpen(&b, id);
    EjBufText(&b, ",\"handle\":\"pool#");
    EjBufInt(&b, p->used);
    EjBufText(&b, "\",\"rows\":");
    EjBufInt(&b, rows);
    EjBufText(&b, ",\"fields\":[");
    for (int c = 0; c < ncols; c++) {
        if (c > 0) {
            EjBufText(&b, ",");
        }
        EjBufString(&b, p->cols[c].name, strlen(p->cols[c].name));
    }
    EjBufText(&b, "]}");
    SendBuf(&b);
}

static void
OpDef(int64_t id, const Ej *req)
{
    Ej *name = EjGet(req, "name");
    Ej *chunk = EjGet(req, "chunk");
    if (name == NULL || name->kind != EJ_STRING || chunk == NULL ||
            chunk->kind != EJ_STRING) {
        SendError(id, "usage", "def expects string name and chunk");
        return;
    }
    if (!NameOk(name->u.s.bytes, name->u.s.len)) {
        SendError(id, "badvalue", "kernel names are [A-Za-z_][A-Za-z0-9_]*, "
                  "shorter than 64 bytes");
        return;
    }
    uint64_t hash = Fnv1a(chunk->u.s.bytes, chunk->u.s.len);
    Kernel *k = KernelFind(name->u.s.bytes);
    if (k != NULL && k->hash == hash) {
        k->lastUse = ++gKernelClock;
        EjBuf b;
        OkOpen(&b, id);
        EjBufText(&b, ",\"name\":");
        EjBufString(&b, name->u.s.bytes, name->u.s.len);
        EjBufText(&b, ",\"cached\":true}");
        SendBuf(&b);
        return;
    }
    for (int i = 0; i < gNStates; i++) {
        lua_State *S = gStates[i].L;
        lua_pushcfunction(S, MsgHandler);
        if (luaL_loadbuffer(S, chunk->u.s.bytes, chunk->u.s.len,
                            name->u.s.bytes) != LUA_OK ||
                lua_pcall(S, 0, 0, -2) != LUA_OK) {
            char msg[512];
            snprintf(msg, sizeof(msg), "compile failed in state %d: %s", i,
                     lua_tostring(S, -1));
            lua_settop(S, 0);
            SendError(id, "lua", msg);
            return;
        }
        lua_settop(S, 0);
        lua_getglobal(S, name->u.s.bytes);
        int isfn = lua_isfunction(S, -1);
        lua_settop(S, 0);
        if (!isfn) {
            char msg[192];
            snprintf(msg, sizeof(msg),
                     "chunk did not define global function %s",
                     name->u.s.bytes);
            SendError(id, "lua", msg);
            return;
        }
    }
    if (k == NULL) {
        for (int i = 0; i < ENGINE_MAX_KERNELS; i++) {
            if (!gKernels[i].used) {
                k = &gKernels[i];
                break;
            }
        }
        if (k == NULL) {
            /* Evict the least recently used kernel: clear its global in
             * every state so a later run of that name refuses cleanly. */
            Kernel *victim = &gKernels[0];
            for (int i = 1; i < ENGINE_MAX_KERNELS; i++) {
                if (gKernels[i].lastUse < victim->lastUse) {
                    victim = &gKernels[i];
                }
            }
            for (int i = 0; i < gNStates; i++) {
                lua_pushnil(gStates[i].L);
                lua_setglobal(gStates[i].L, victim->name);
            }
            gKernelEvictions++;
            k = victim;
        }
        k->used = 1;
        snprintf(k->name, sizeof(k->name), "%s", name->u.s.bytes);
    }
    k->hash = hash;
    k->lastUse = ++gKernelClock;
    EjBuf b;
    OkOpen(&b, id);
    EjBufText(&b, ",\"name\":");
    EjBufString(&b, name->u.s.bytes, name->u.s.len);
    EjBufText(&b, ",\"hash\":\"");
    char hh[17];
    snprintf(hh, sizeof(hh), "%016llx", (unsigned long long)hash);
    EjBufText(&b, hh);
    EjBufText(&b, "\"}");
    SendBuf(&b);
}

/* Push the arguments for one call into S. The pool argument (at most one in
 * Phase 2) receives the view [a,b). Returns arg count or -1. */
static int
PushArgs(lua_State *S, int stateIdx, const Ej *args, int64_t a, int64_t b,
         ConvErr *e)
{
    if (args == NULL) {
        return 0;
    }
    int n = 0;
    for (size_t i = 0; i < args->u.a.count; i++) {
        Ej *v = args->u.a.items[i];
        Ej *h = (v->kind == EJ_OBJECT) ? EjGet(v, "handle") : NULL;
        if (h != NULL && v->u.a.count == 1 && h->kind == EJ_STRING) {
            int poolNum = 0;
            Pool *p = PoolByHandle(h->u.s.bytes, &poolNum);
            if (p != NULL) {
                int64_t lo = (a < 0) ? 0 : a;
                int64_t hi = (b < 0) ? p->rows : b;
                PushPoolView(S, stateIdx, p, poolNum, lo, hi);
                n++;
                continue;
            }
            if (strncmp(h->u.s.bytes, "res#", 4) == 0) {
                int rn = 0;
                if (sscanf(h->u.s.bytes, "res#%d", &rn) == 1) {
                    for (int ri = 0; ri < ENGINE_MAX_RESULTS; ri++) {
                        if (gResults[ri].used == rn) {
                            if (stateIdx != 0) {
                                snprintf(e->msg, sizeof(e->msg),
                                    "a result handle joins single runs only");
                                return -1;
                            }
                            lua_rawgeti(S, LUA_REGISTRYINDEX,
                                        gResults[ri].ref);
                            n++;
                            goto next;
                        }
                    }
                }
            }
            snprintf(e->msg, sizeof(e->msg), "unknown handle %s",
                     h->u.s.bytes);
            return -1;
        }
        if (!EjToLua(S, v, 0, e)) {
            return -1;
        }
        n++;
next:   ;
    }
    return n;
}

typedef struct {
    int stateIdx;
    const char *name;
    const Ej *args;
    int64_t a, b;
    int resultRef;
    int failed;
    char err[512];
} RunWork;

static unsigned __stdcall
RunWorker(void *arg)
{
    RunWork *w = (RunWork *)arg;
    lua_State *S = gStates[w->stateIdx].L;
    ConvErr ce;
    lua_pushcfunction(S, MsgHandler);
    lua_getglobal(S, w->name);
    if (!lua_isfunction(S, -1)) {
        snprintf(w->err, sizeof(w->err), "no kernel %s", w->name);
        w->failed = 1;
        lua_settop(S, 0);
        return 0;
    }
    int n = PushArgs(S, w->stateIdx, w->args, w->a, w->b, &ce);
    if (n < 0) {
        snprintf(w->err, sizeof(w->err), "%s", ce.msg);
        w->failed = 2;                             /* type/nohandle class */
        lua_settop(S, 0);
        return 0;
    }
    if (lua_pcall(S, n, 1, 1) != LUA_OK) {
        snprintf(w->err, sizeof(w->err), "%s", lua_tostring(S, -1));
        w->failed = 1;
        lua_settop(S, 0);
        return 0;
    }
    w->resultRef = luaL_ref(S, LUA_REGISTRYINDEX);
    lua_settop(S, 0);
    return 0;
}

/* Encode/spill the single result sitting at the top of state0's stack. */
static void
ReplySingleResult(int64_t id, lua_State *S0, double ms)
{
    ConvErr ce;
    EjBuf val;
    EjBufInit(&val);
    if (!LuaToJson(S0, -1, &val, 0, 1, &ce)) {
        lua_pop(S0, 1);
        EjBufFree(&val);
        SendError(id, "type", ce.msg);
        return;
    }
    EjBuf b;
    OkOpen(&b, id);
    if (val.len > ENGINE_VALUE_CEIL) {
        EjBufFree(&val);
        int slot = -1;
        for (int i = 0; i < ENGINE_MAX_RESULTS; i++) {
            if (!gResults[i].used) {
                slot = i;
                break;
            }
        }
        if (slot < 0) {
            lua_pop(S0, 1);
            EjBufFree(&b);
            SendError(id, "badvalue", "result table is full (free some)");
            return;
        }
        gResults[slot].used = ++gResultSeq;
        gResults[slot].ref = luaL_ref(S0, LUA_REGISTRYINDEX);
        gStats.spills++;
        EjBufText(&b, ",\"handle\":\"res#");
        EjBufInt(&b, gResults[slot].used);
        EjBufText(&b, "\",\"spilled\":true,\"ms\":");
        EjBufDouble(&b, ms);
        EjBufText(&b, "}");
        SendBuf(&b);
        return;
    }
    lua_pop(S0, 1);
    EjBufText(&b, ",\"value\":");
    EjBufRaw(&b, val.bytes != NULL ? val.bytes : "null", val.len);
    EjBufFree(&val);
    EjBufText(&b, ",\"ms\":");
    EjBufDouble(&b, ms);
    EjBufText(&b, "}");
    SendBuf(&b);
}

static void
OpRun(int64_t id, const Ej *req)
{
    Ej *name = EjGet(req, "name");
    Ej *args = EjGet(req, "args");
    Ej *shardsE = EjGet(req, "shards");
    Ej *reduceE = EjGet(req, "reduce");
    if (name == NULL || name->kind != EJ_STRING ||
            (args != NULL && args->kind != EJ_ARRAY)) {
        SendError(id, "usage", "run expects string name and array args");
        return;
    }
    Kernel *kr = KernelFind(name->u.s.bytes);
    if (kr == NULL) {
        char msg[128];
        snprintf(msg, sizeof(msg), "no kernel %s (def it first)",
                 name->u.s.bytes);
        SendError(id, "lua", msg);
        return;
    }
    kr->lastUse = ++gKernelClock;
    int shards = 0;
    if (shardsE != NULL) {
        if (shardsE->kind != EJ_INT || shardsE->u.i < 1 ||
                shardsE->u.i > gNStates) {
            char msg[96];
            snprintf(msg, sizeof(msg),
                     "shards must be an integer 1..%d (engine threads)",
                     gNStates);
            SendError(id, "badvalue", msg);
            return;
        }
        shards = (int)shardsE->u.i;
    }
    if (reduceE != NULL && (reduceE->kind != EJ_STRING ||
            KernelFind(reduceE->u.s.bytes) == NULL)) {
        SendError(id, "badvalue", "reduce names a defined kernel");
        return;
    }
    gStats.runs++;
    lua_State *S0 = gStates[0].L;

    if (shards == 0) {
        /* Single run in state 0 over the full range. */
        RunWork w;
        memset(&w, 0, sizeof(w));
        w.stateIdx = 0;
        w.name = name->u.s.bytes;
        w.args = args;
        w.a = -1;
        w.b = -1;
        double t0 = NowMs();
        RunWorker(&w);
        double ms = NowMs() - t0;
        if (w.failed) {
            SendError(id, (w.failed == 2)
                ? (strstr(w.err, "handle") != NULL ? "nohandle" : "type")
                : "lua", w.err);
            return;
        }
        lua_rawgeti(S0, LUA_REGISTRYINDEX, w.resultRef);
        luaL_unref(S0, LUA_REGISTRYINDEX, w.resultRef);
        ReplySingleResult(id, S0, ms);
        return;
    }

    /* Sharded: the first pool argument is viewed per contiguous range. */
    Pool *pool = NULL;
    if (args != NULL) {
        for (size_t i = 0; i < args->u.a.count; i++) {
            Ej *v = args->u.a.items[i];
            Ej *h = (v->kind == EJ_OBJECT) ? EjGet(v, "handle") : NULL;
            if (h != NULL && h->kind == EJ_STRING) {
                pool = PoolByHandle(h->u.s.bytes, NULL);
                if (pool != NULL) {
                    break;
                }
            }
        }
    }
    if (pool == NULL) {
        SendError(id, "badvalue", "sharded runs need a pool handle argument");
        return;
    }
    RunWork work[ENGINE_MAXSTATES];
    HANDLE th[ENGINE_MAXSTATES];
    int64_t base = pool->rows / shards, extra = pool->rows % shards, off = 0;
    double t0 = NowMs();
    for (int i = 0; i < shards; i++) {
        int64_t take = base + (i < extra ? 1 : 0);
        memset(&work[i], 0, sizeof(work[i]));
        work[i].stateIdx = i;
        work[i].name = name->u.s.bytes;
        work[i].args = args;
        work[i].a = off;
        work[i].b = off + take;
        off += take;
        uintptr_t h = _beginthreadex(NULL, 0, RunWorker, &work[i], 0, NULL);
        if (h == 0) {
            for (int k2 = 0; k2 < i; k2++) {
                WaitForSingleObject(th[k2], INFINITE);
                CloseHandle(th[k2]);
            }
            SendError(id, "badvalue", "thread creation failed");
            return;
        }
        th[i] = (HANDLE)h;
    }
    WaitForMultipleObjects((DWORD)shards, th, TRUE, INFINITE);
    double ms = NowMs() - t0;
    for (int i = 0; i < shards; i++) {
        CloseHandle(th[i]);
    }
    int failedAt = -1;
    for (int i = 0; i < shards; i++) {
        if (work[i].failed && failedAt < 0) {
            failedAt = i;
        }
    }
    if (failedAt >= 0) {
        for (int i = 0; i < shards; i++) {
            if (!work[i].failed) {
                luaL_unref(gStates[i].L, LUA_REGISTRYINDEX,
                           work[i].resultRef);
            }
        }
        char msg[560];
        snprintf(msg, sizeof(msg), "shard %d: %s", failedAt,
                 work[failedAt].err);
        SendError(id, (work[failedAt].failed == 2) ? "type" : "lua", msg);
        return;
    }
    /* Assemble the partials as a sequence in state 0 (cross-state values
     * travel by encode/decode; partials are summaries by design). */
    ConvErr ce;
    lua_createtable(S0, shards, 0);
    for (int i = 0; i < shards; i++) {
        lua_State *Si = gStates[i].L;
        lua_rawgeti(Si, LUA_REGISTRYINDEX, work[i].resultRef);
        EjBuf pb;
        EjBufInit(&pb);
        int ok = LuaToJson(Si, -1, &pb, 0, 1, &ce);
        lua_pop(Si, 1);
        luaL_unref(Si, LUA_REGISTRYINDEX, work[i].resultRef);
        if (!ok) {
            EjBufFree(&pb);
            lua_pop(S0, 1);
            char msg[320];
            snprintf(msg, sizeof(msg), "shard %d result: %s", i, ce.msg);
            SendError(id, "type", msg);
            return;
        }
        const char *perr = NULL;
        Ej *pv = EjParse(pb.bytes, pb.len, &perr);
        EjBufFree(&pb);
        if (pv == NULL || !EjToLua(S0, pv, 0, &ce)) {
            EjFree(pv);
            lua_pop(S0, 1);
            SendError(id, "type", "partial could not re-enter state 0");
            return;
        }
        EjFree(pv);
        lua_rawseti(S0, -2, (lua_Integer)(i + 1));
    }
    if (reduceE != NULL) {
        lua_pushcfunction(S0, MsgHandler);
        lua_getglobal(S0, reduceE->u.s.bytes);
        lua_rotate(S0, -3, 2);                    /* msgh, fn, partials */
        int msgh = lua_gettop(S0) - 2;
        if (lua_pcall(S0, 1, 1, msgh) != LUA_OK) {
            char msg[560];
            snprintf(msg, sizeof(msg), "reduce: %s", lua_tostring(S0, -1));
            lua_settop(S0, 0);
            SendError(id, "lua", msg);
            return;
        }
        lua_remove(S0, -2);                       /* drop msgh */
    }
    ReplySingleResult(id, S0, ms);
}

static void
OpFree(int64_t id, const Ej *req)
{
    Ej *h = EjGet(req, "handle");
    if (h == NULL || h->kind != EJ_STRING) {
        SendError(id, "usage", "free expects a handle");
        return;
    }
    Pool *p = PoolByHandle(h->u.s.bytes, NULL);
    if (p != NULL) {
        PoolFree(p);
        EjBuf b;
        OkOpen(&b, id);
        EjBufText(&b, "}");
        SendBuf(&b);
        return;
    }
    int rn = 0;
    if (sscanf(h->u.s.bytes, "res#%d", &rn) == 1) {
        for (int i = 0; i < ENGINE_MAX_RESULTS; i++) {
            if (gResults[i].used == rn) {
                luaL_unref(gStates[0].L, LUA_REGISTRYINDEX, gResults[i].ref);
                gResults[i].used = 0;
                EjBuf b;
                OkOpen(&b, id);
                EjBufText(&b, "}");
                SendBuf(&b);
                return;
            }
        }
    }
    char msg[160];
    snprintf(msg, sizeof(msg), "unknown handle %s", h->u.s.bytes);
    SendError(id, "nohandle", msg);
}

static void
OpStats(int64_t id)
{
    EjBuf b;
    OkOpen(&b, id);
    EjBufText(&b, ",\"engine\":\"machteld\",\"uptime_ms\":");
    EjBufInt(&b, (int64_t)(GetTickCount64() - gStats.t0));
    EjBufText(&b, ",\"threads\":");
    EjBufInt(&b, gNStates);
    EjBufText(&b, ",\"frames\":");
    EjBufInt(&b, (int64_t)gStats.frames);
    EjBufText(&b, ",\"bytes_in\":");
    EjBufInt(&b, (int64_t)gStats.bytesIn);
    EjBufText(&b, ",\"bytes_out\":");
    EjBufInt(&b, (int64_t)gStats.bytesOut);
    EjBufText(&b, ",\"runs\":");
    EjBufInt(&b, (int64_t)gStats.runs);
    EjBufText(&b, ",\"spills\":");
    EjBufInt(&b, (int64_t)gStats.spills);
    /* Occupancy gauges (the PHM spike's Plimsoll lines): how close each
     * bounded table and each state's cap is to its edge. */
    int kernels = 0, results = 0, views = 0;
    for (int i = 0; i < ENGINE_MAX_KERNELS; i++) { kernels += gKernels[i].used ? 1 : 0; }
    for (int i = 0; i < ENGINE_MAX_RESULTS; i++) { results += gResults[i].used ? 1 : 0; }
    for (int i = 0; i < ENGINE_MAX_POOLS; i++) { views += gPools[i].used ? gPools[i].nviews : 0; }
    EjBufText(&b, ",\"kernels\":");
    EjBufInt(&b, kernels);
    EjBufText(&b, ",\"kernel_slots\":");
    EjBufInt(&b, ENGINE_MAX_KERNELS);
    EjBufText(&b, ",\"kernel_evictions\":");
    EjBufInt(&b, (int64_t)gKernelEvictions);
    EjBufText(&b, ",\"results\":");
    EjBufInt(&b, results);
    EjBufText(&b, ",\"result_slots\":");
    EjBufInt(&b, ENGINE_MAX_RESULTS);
    EjBufText(&b, ",\"views\":");
    EjBufInt(&b, views);
    EjBufText(&b, ",\"view_evictions\":");
    EjBufInt(&b, (int64_t)gStats.viewEvictions);
    EjBufText(&b, ",\"cap_bytes\":");
    EjBufInt(&b, (int64_t)ENGINE_STATE_CAP_MB * 1024 * 1024);
    EjBufText(&b, ",\"dict_limit\":");
    EjBufInt(&b, DictLimit());
    EjBufText(&b, ",\"mem_used\":[");
    for (int i = 0; i < gNStates; i++) {
        if (i > 0) {
            EjBufText(&b, ",");
        }
        EjBufInt(&b, (int64_t)gStates[i].alloc.used);
    }
    EjBufText(&b, "],\"pools\":[");
    int first = 1;
    for (int i = 0; i < ENGINE_MAX_POOLS; i++) {
        if (gPools[i].used) {
            if (!first) {
                EjBufText(&b, ",");
            }
            first = 0;
            int dcols = 0, scols = 0;
            for (int c = 0; c < gPools[i].ncols; c++) {
                if (gPools[i].cols[c].type == 's') {
                    if (gPools[i].cols[c].dictN > 0) {
                        dcols++;
                    } else {
                        scols++;
                    }
                }
            }
            EjBufText(&b, "{\"handle\":\"pool#");
            EjBufInt(&b, gPools[i].used);
            EjBufText(&b, "\",\"rows\":");
            EjBufInt(&b, gPools[i].rows);
            EjBufText(&b, ",\"dict_cols\":");
            EjBufInt(&b, dcols);
            EjBufText(&b, ",\"span_cols\":");
            EjBufInt(&b, scols);
            EjBufText(&b, "}");
        }
    }
    EjBufText(&b, "]}");
    SendBuf(&b);
}

/* ---------------- entry ---------------- */

int
Machteld_EngineMain(int threads)
{
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    InitializeCriticalSection(&gViewLock);
    gColOk = __builtin_cpu_supports("avx2");
    gStats.t0 = GetTickCount64();

    if (threads < 1 || threads > ENGINE_MAXSTATES) {
        SYSTEM_INFO si;
        GetSystemInfo(&si);
        threads = (int)si.dwNumberOfProcessors;
        if (threads > 16) {
            threads = 16;
        }
        if (threads < 1) {
            threads = 1;
        }
    }
    for (int i = 0; i < threads; i++) {
        gStates[i].L = NewMeteredState(&gStates[i].alloc);
        if (gStates[i].L == NULL) {
            return 3;
        }
    }
    gNStates = threads;

    for (;;) {
        size_t len = 0;
        char *frame = ReadFrame(&len);
        if (frame == NULL) {
            break;                                 /* host is gone */
        }
        const char *perr = NULL;
        Ej *req = EjParse(frame, len, &perr);
        free(frame);
        if (req == NULL || req->kind != EJ_OBJECT) {
            EjFree(req);
            SendError(0, "protocol",
                      (perr != NULL) ? perr : "request must be a JSON object");
            continue;
        }
        Ej *idE = EjGet(req, "id");
        Ej *opE = EjGet(req, "op");
        if (idE == NULL || idE->kind != EJ_INT || idE->u.i < 1 ||
                opE == NULL || opE->kind != EJ_STRING) {
            EjFree(req);
            SendError(0, "protocol", "request needs integer id and string op");
            continue;
        }
        int64_t id = idE->u.i;
        const char *op = opE->u.s.bytes;
        if (!gHelloDone && strcmp(op, "hello") != 0) {
            SendError(id, "protocol", "the first request is hello");
            EjFree(req);
            continue;
        }
        if (strcmp(op, "hello") == 0) {
            OpHello(id, req);
        } else if (strcmp(op, "load") == 0) {
            OpLoad(id, req);
        } else if (strcmp(op, "def") == 0) {
            OpDef(id, req);
        } else if (strcmp(op, "run") == 0) {
            OpRun(id, req);
        } else if (strcmp(op, "free") == 0) {
            OpFree(id, req);
        } else if (strcmp(op, "stats") == 0) {
            OpStats(id);
        } else if (strcmp(op, "cancel") == 0) {
            EjBuf b;
            OkOpen(&b, id);
            EjBufText(&b, "}");                    /* advisory: acknowledged */
            SendBuf(&b);
        } else if (strcmp(op, "quit") == 0) {
            EjBuf b;
            OkOpen(&b, id);
            EjBufText(&b, "}");
            SendBuf(&b);
            EjFree(req);
            break;
        } else {
            char msg[128];
            snprintf(msg, sizeof(msg), "unknown op %s", op);
            SendError(id, "usage", msg);
        }
        EjFree(req);
    }
    for (int i = 0; i < gNStates; i++) {
        lua_close(gStates[i].L);
    }
    return 0;
}
