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

typedef struct {
    char name[64];
    uint64_t hash;
    int used;
} Kernel;
static Kernel gKernels[ENGINE_MAX_KERNELS];

typedef struct {
    int state;
    char key[64];
} ViewRef;

typedef struct {
    int used;
    int64_t rows;
    char *bytes;                     /* one allocation holding every line */
    int64_t *offs;
    int64_t *lens;
    ViewRef *views;
    int nviews, capviews;
} Pool;
static Pool gPools[ENGINE_MAX_POOLS];
static int gPoolSeq = 0;

typedef struct {
    int used;
    int ref;                         /* registry ref in state 0 */
} Result;
static Result gResults[ENGINE_MAX_RESULTS];
static int gResultSeq = 0;

/* ---------------- stats ---------------- */

static struct {
    uint64_t frames, bytesIn, bytesOut, runs, spills;
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

static void
PoolTrackView(Pool *p, int state, const char *key)
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

/* Push the pool view [a,b) as the kernel-visible object: h.rows plus one
 * materialized column sequence h.line. Cached per (state, range) in that
 * state's registry, per the contract's materialized-columns promise. */
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
    lua_createtable(S, 0, 2);
    lua_pushinteger(S, (lua_Integer)n);
    lua_setfield(S, -2, "rows");
    lua_createtable(S, (int)n, 0);
    for (int64_t i = 0; i < n; i++) {
        lua_pushlstring(S, p->bytes + p->offs[a + i], (size_t)p->lens[a + i]);
        lua_rawseti(S, -2, (lua_Integer)(i + 1));
    }
    lua_setfield(S, -2, "line");
    lua_pushvalue(S, -1);
    lua_setfield(S, LUA_REGISTRYINDEX, key);
    PoolTrackView(p, stateIdx, key);
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
    free(p->bytes);
    free(p->offs);
    free(p->lens);
    memset(p, 0, sizeof(*p));
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
        "[\"lua\",\"load.lines\",\"shards\",\"reduce\",\"stats\"]}");
    SendBuf(&b);
}

static void
OpLoad(int64_t id, const Ej *req)
{
    Ej *fmt = EjGet(req, "format");
    Ej *path = EjGet(req, "path");
    if (fmt == NULL || fmt->kind != EJ_STRING || path == NULL ||
            path->kind != EJ_STRING) {
        SendError(id, "usage", "load expects string format and path");
        return;
    }
    if (strcmp(fmt->u.s.bytes, "lines") != 0) {
        SendError(id, "refused", "this engine loads format \"lines\" only "
                  "(csv arrives with a later capability)");
        return;
    }
    int wlen = MultiByteToWideChar(CP_UTF8, 0, path->u.s.bytes, -1, NULL, 0);
    WCHAR *wpath = (WCHAR *)malloc((size_t)wlen * sizeof(WCHAR));
    if (wpath == NULL || wlen == 0) {
        free(wpath);
        SendError(id, "badvalue", "path conversion failed");
        return;
    }
    MultiByteToWideChar(CP_UTF8, 0, path->u.s.bytes, -1, wpath, wlen);
    FILE *fh = _wfopen(wpath, L"rb");
    free(wpath);
    if (fh == NULL) {
        SendError(id, "badvalue", "cannot open the path for reading");
        return;
    }
    _fseeki64(fh, 0, SEEK_END);
    long long size = _ftelli64(fh);
    _fseeki64(fh, 0, SEEK_SET);
    if (size < 0) {
        fclose(fh);
        SendError(id, "badvalue", "cannot size the file");
        return;
    }
    char *bytes = (char *)malloc((size_t)size + 1);
    if (bytes == NULL) {
        fclose(fh);
        SendError(id, "memory", "file does not fit in engine memory");
        return;
    }
    if (size > 0 && fread(bytes, 1, (size_t)size, fh) != (size_t)size) {
        free(bytes);
        fclose(fh);
        SendError(id, "badvalue", "short read");
        return;
    }
    fclose(fh);

    int slot = -1;
    for (int i = 0; i < ENGINE_MAX_POOLS; i++) {
        if (!gPools[i].used) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        free(bytes);
        SendError(id, "badvalue", "too many pools (free some)");
        return;
    }
    int64_t rows = 0;
    for (long long i = 0; i < size; i++) {
        if (bytes[i] == '\n') {
            rows++;
        }
    }
    if (size > 0 && bytes[size - 1] != '\n') {
        rows++;                                     /* final unterminated line */
    }
    int64_t *offs = (int64_t *)malloc((size_t)(rows > 0 ? rows : 1) * 8);
    int64_t *lens = (int64_t *)malloc((size_t)(rows > 0 ? rows : 1) * 8);
    if (offs == NULL || lens == NULL) {
        free(bytes);
        free(offs);
        free(lens);
        SendError(id, "memory", "index does not fit in engine memory");
        return;
    }
    int64_t r = 0;
    long long start = 0;
    for (long long i = 0; i <= size; i++) {
        if (i == size || bytes[i] == '\n') {
            if (i == size && start == i) {
                break;                              /* no final empty row */
            }
            long long end = i;
            if (end > start && bytes[end - 1] == '\r') {
                end--;                              /* CRLF */
            }
            offs[r] = start;
            lens[r] = end - start;
            r++;
            start = i + 1;
        }
    }
    Pool *p = &gPools[slot];
    memset(p, 0, sizeof(*p));
    p->used = ++gPoolSeq;
    p->rows = r;
    p->bytes = bytes;
    p->offs = offs;
    p->lens = lens;

    EjBuf b;
    OkOpen(&b, id);
    EjBufText(&b, ",\"handle\":\"pool#");
    EjBufInt(&b, p->used);
    EjBufText(&b, "\",\"rows\":");
    EjBufInt(&b, r);
    EjBufText(&b, ",\"fields\":[\"line\"]}");
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
            SendError(id, "badvalue", "kernel table is full");
            return;
        }
        k->used = 1;
        snprintf(k->name, sizeof(k->name), "%s", name->u.s.bytes);
    }
    k->hash = hash;
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
    if (KernelFind(name->u.s.bytes) == NULL) {
        char msg[128];
        snprintf(msg, sizeof(msg), "no kernel %s (def it first)",
                 name->u.s.bytes);
        SendError(id, "lua", msg);
        return;
    }
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
            EjBufText(&b, "{\"handle\":\"pool#");
            EjBufInt(&b, gPools[i].used);
            EjBufText(&b, "\",\"rows\":");
            EjBufInt(&b, gPools[i].rows);
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
