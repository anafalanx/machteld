/*
 * lua.c -- ::machteld::LuaCell: metered Lua 5.5 cells for generated kernels.
 *
 * PRIVATE primitive, deliberately absent from the public manifest: the public
 * verb is `macht` (Tcl, in the prelude), which parses a Tcl-expr surface,
 * generates both a Tcl arm and a Lua arm from one AST, and proves them equal
 * before trusting either. Nothing here is a user-facing language; the seam is
 * closed by decision (2026-08-19), and this file is the machinery under it.
 *
 * THE DECISION THAT MATTERS HERE is metering. A cell is a lua_State that
 * cannot exceed its memory cap (a counting allocator refuses growth), cannot
 * run away (a count hook raises after the instruction budget), and cannot
 * touch the machine (base/string/math/table only -- no io, no os, no
 * package). Lua raises; pcall catches; the caller gets a Tcl error with a
 * MACHT code. Errors are longjmp, never C++ unwinding: Lua is COMPILED AS C.
 *
 * THE THREADING LAW, bought in the reken spike: the pool's workers touch
 * ONLY their own lua_State. Every Tcl_Obj stays on the interp's thread, which
 * is why sharding marshals serially; and the allocator below is CRT malloc,
 * never Tcl_Alloc -- Lua allocates DURING worker execution, on threads Tcl
 * has never heard of, and Tcl's allocator belongs to Tcl-registered threads.
 */
#undef USE_TCL_STUBS
#include "machteld.h"

#ifdef MACHTELD_LUA

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <process.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#define MLUA_MAX_POOL 32
/* Fixed string-hash seed: reproducible runs; the states are internal, there
 * are no attacker-supplied keys to defend against. */
#define MLUA_HASH_SEED 2654435769u

typedef struct {
    size_t used;
    size_t cap;
} mlua_alloc;

typedef struct {
    lua_State *L;
    mlua_alloc alloc;
} mlua_slot;

typedef struct {
    mlua_slot cell;                  /* the single state          */
    int cell_open;
    mlua_slot pool[MLUA_MAX_POOL];   /* the parallel shard states */
    int pool_n;
} mlua_state;

typedef struct {
    lua_State *L;
    const char *fname;
    Tcl_WideInt result;
    int failed;
    char err[512];
} mlua_work;

static int
mlua_error(Tcl_Interp *interp, const char *code, const char *msg)
{
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "MACHT", code, (char *)NULL);
    return TCL_ERROR;
}

static int
mlua_errorf(Tcl_Interp *interp, const char *code, Tcl_Obj *msg)
{
    Tcl_SetObjResult(interp, msg);
    Tcl_SetErrorCode(interp, "MACHTELD", "MACHT", code, (char *)NULL);
    return TCL_ERROR;
}

/* Lua allocator contract: ptr==NULL is a fresh allocation (osize is a kind
 * tag, not a size); nsize==0 frees. Growth beyond the cap is refused, which
 * Lua converts into a memory error caught by the surrounding pcall. */
static void *
mlua_alloc_f(void *ud, void *ptr, size_t osize, size_t nsize)
{
    mlua_alloc *a = (mlua_alloc *)ud;
    size_t old = (ptr != NULL) ? osize : 0;
    if (nsize == 0) {
        a->used -= old;
        free(ptr);
        return NULL;
    }
    if (a->cap != 0 && nsize > old && a->used - old + nsize > a->cap) {
        return NULL;
    }
    void *nptr = realloc(ptr, nsize);    /* realloc(NULL, n) is malloc(n) */
    if (nptr == NULL) {
        return NULL;
    }
    a->used = a->used - old + nsize;
    return nptr;
}

static void
mlua_hook(lua_State *S, lua_Debug *ar)
{
    (void)ar;
    luaL_error(S, "machteld: instruction budget exhausted");
}

static lua_State *
mlua_new_state(mlua_alloc *a, Tcl_WideInt cap_mb)
{
    a->used = 0;
    a->cap = (size_t)cap_mb * 1024 * 1024;
    lua_State *S = lua_newstate(mlua_alloc_f, a, MLUA_HASH_SEED);
    if (S == NULL) {
        return NULL;
    }
    luaL_requiref(S, LUA_GNAME, luaopen_base, 1);
    luaL_requiref(S, LUA_STRLIBNAME, luaopen_string, 1);
    luaL_requiref(S, LUA_MATHLIBNAME, luaopen_math, 1);
    luaL_requiref(S, LUA_TABLIBNAME, luaopen_table, 1);
    lua_settop(S, 0);
    return S;
}

static void
mlua_close_cell(mlua_state *st)
{
    if (st->cell_open) {
        lua_close(st->cell.L);
        st->cell.L = NULL;
        st->cell_open = 0;
    }
}

static void
mlua_close_pool(mlua_state *st)
{
    for (int i = 0; i < st->pool_n; i++) {
        if (st->pool[i].L != NULL) {
            lua_close(st->pool[i].L);
            st->pool[i].L = NULL;
        }
    }
    st->pool_n = 0;
}

/* Compile `src` and require it to have defined global function `name`. */
static int
mlua_compile_into(Tcl_Interp *interp, lua_State *S, Tcl_Obj *nameObj,
                  Tcl_Obj *srcObj, const char *where)
{
    Tcl_Size srcLen;
    const char *name = Tcl_GetString(nameObj);
    const char *src = Tcl_GetStringFromObj(srcObj, &srcLen);
    if (luaL_loadbuffer(S, src, (size_t)srcLen, name) != LUA_OK ||
            lua_pcall(S, 0, 0, 0) != LUA_OK) {
        Tcl_Obj *msg = Tcl_ObjPrintf("machteld: lua compile failed%s: %s",
                                     where, lua_tostring(S, -1));
        lua_settop(S, 0);
        return mlua_errorf(interp, "compile", msg);
    }
    lua_getglobal(S, name);
    int isfn = lua_isfunction(S, -1);
    lua_settop(S, 0);
    if (!isfn) {
        return mlua_errorf(interp, "compile", Tcl_ObjPrintf(
            "machteld: chunk did not define global function %s", name));
    }
    return TCL_OK;
}

/* Build a DATA table in S from rows[0..nrows). INTERP THREAD ONLY: this
 * walks Tcl_Objs. Types: i pushes a 64-bit integer, anything else pushes
 * the value's UTF-8 bytes. */
static int
mlua_load_rows(Tcl_Interp *interp, lua_State *S, Tcl_Obj **rows,
               Tcl_Size nrows, Tcl_Obj **types, Tcl_Size ntypes)
{
    lua_createtable(S, (int)nrows, 0);
    for (Tcl_Size r = 0; r < nrows; r++) {
        Tcl_Size nf;
        Tcl_Obj **fields;
        if (Tcl_ListObjGetElements(interp, rows[r], &nf, &fields) != TCL_OK) {
            lua_settop(S, 0);
            return TCL_ERROR;
        }
        if (nf != ntypes) {
            lua_settop(S, 0);
            return mlua_errorf(interp, "badvalue", Tcl_ObjPrintf(
                "machteld: row %d has %d fields, schema has %d",
                (int)r, (int)nf, (int)ntypes));
        }
        lua_createtable(S, (int)nf, 0);
        for (Tcl_Size f = 0; f < nf; f++) {
            if (Tcl_GetString(types[f])[0] == 'i') {
                Tcl_WideInt v;
                if (Tcl_GetWideIntFromObj(interp, fields[f], &v) != TCL_OK) {
                    lua_settop(S, 0);
                    return TCL_ERROR;
                }
                lua_pushinteger(S, (lua_Integer)v);
            } else {
                Tcl_Size len;
                const char *s = Tcl_GetStringFromObj(fields[f], &len);
                lua_pushlstring(S, s, (size_t)len);
            }
            lua_rawseti(S, -2, (lua_Integer)(f + 1));
        }
        lua_rawseti(S, -2, (lua_Integer)(r + 1));
    }
    lua_setglobal(S, "DATA");
    return TCL_OK;
}

/* Worker body: runs on its own thread against its own state. No Tcl API. */
static unsigned __stdcall
mlua_worker(void *arg)
{
    mlua_work *w = (mlua_work *)arg;
    lua_State *S = w->L;
    lua_getglobal(S, w->fname);
    if (!lua_isfunction(S, -1)) {
        snprintf(w->err, sizeof(w->err), "no compiled function %s", w->fname);
        w->failed = 1;
        lua_settop(S, 0);
        return 0;
    }
    lua_getglobal(S, "DATA");
    if (lua_pcall(S, 1, 1, 0) != LUA_OK) {
        const char *e = lua_tostring(S, -1);
        snprintf(w->err, sizeof(w->err), "%s", e ? e : "(no message)");
        w->failed = 1;
        lua_settop(S, 0);
        return 0;
    }
    if (!lua_isinteger(S, -1)) {
        snprintf(w->err, sizeof(w->err),
                 "parallel kernels must return integers (monoid reduce)");
        w->failed = 1;
        lua_settop(S, 0);
        return 0;
    }
    w->result = (Tcl_WideInt)lua_tointeger(S, -1);
    lua_settop(S, 0);
    return 0;
}

/* ---- subcommands ---------------------------------------------------------- */

static int
mlua_open(mlua_state *st, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    Tcl_WideInt cap_mb = 256;
    if (objc > 3) {
        return mlua_error(interp, "badvalue",
            "wrong # args: should be \"::machteld::LuaCell open ?memcap_mb?\"");
    }
    if (objc == 3 && Tcl_GetWideIntFromObj(interp, objv[2], &cap_mb) != TCL_OK) {
        return TCL_ERROR;
    }
    if (cap_mb <= 0) {
        return mlua_error(interp, "badvalue", "memcap_mb must be positive");
    }
    mlua_close_cell(st);
    st->cell.L = mlua_new_state(&st->cell.alloc, cap_mb);
    if (st->cell.L == NULL) {
        return mlua_error(interp, "state", "lua state creation failed");
    }
    st->cell_open = 1;
    return TCL_OK;
}

static int
mlua_need_cell(mlua_state *st, Tcl_Interp *interp)
{
    if (!st->cell_open) {
        return mlua_error(interp, "state", "no lua cell (run LuaCell open)");
    }
    return TCL_OK;
}

static int
mlua_need_pool(mlua_state *st, Tcl_Interp *interp)
{
    if (st->pool_n == 0) {
        return mlua_error(interp, "state", "no lua pool (run LuaCell popen)");
    }
    return TCL_OK;
}

static int
mlua_call(mlua_state *st, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    Tcl_WideInt budget = 0;
    if (objc < 3 || objc > 4) {
        return mlua_error(interp, "badvalue",
            "wrong # args: should be \"::machteld::LuaCell call name ?budget?\"");
    }
    if (objc == 4 && Tcl_GetWideIntFromObj(interp, objv[3], &budget) != TCL_OK) {
        return TCL_ERROR;
    }
    if (mlua_need_cell(st, interp) != TCL_OK) {
        return TCL_ERROR;
    }
    lua_State *S = st->cell.L;
    lua_getglobal(S, Tcl_GetString(objv[2]));
    if (!lua_isfunction(S, -1)) {
        lua_settop(S, 0);
        return mlua_errorf(interp, "call", Tcl_ObjPrintf(
            "machteld: no compiled function %s", Tcl_GetString(objv[2])));
    }
    lua_getglobal(S, "DATA");
    if (budget > 0) {
        lua_sethook(S, mlua_hook, LUA_MASKCOUNT, (int)budget);
    } else {
        lua_sethook(S, NULL, 0, 0);
    }
    int rc = lua_pcall(S, 1, 1, 0);
    lua_sethook(S, NULL, 0, 0);
    if (rc != LUA_OK) {
        const char *e = lua_tostring(S, -1);
        Tcl_Obj *msg = Tcl_ObjPrintf("machteld: lua call failed: %s",
                                     e ? e : "(no message)");
        lua_settop(S, 0);
        return mlua_errorf(interp, "call", msg);
    }
    Tcl_Obj *res;
    if (lua_isinteger(S, -1)) {
        res = Tcl_NewWideIntObj((Tcl_WideInt)lua_tointeger(S, -1));
    } else if (lua_type(S, -1) == LUA_TNUMBER) {
        res = Tcl_NewDoubleObj(lua_tonumber(S, -1));
    } else if (lua_type(S, -1) == LUA_TSTRING) {
        size_t len;
        const char *s = lua_tolstring(S, -1, &len);
        res = Tcl_NewStringObj(s, (Tcl_Size)len);
    } else {
        lua_settop(S, 0);
        return mlua_error(interp, "call", "unsupported lua result type");
    }
    lua_settop(S, 0);
    Tcl_SetObjResult(interp, res);
    return TCL_OK;
}

static int
mlua_popen(mlua_state *st, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    Tcl_WideInt n = 0;
    Tcl_WideInt cap_mb = 256;
    if (objc > 4) {
        return mlua_error(interp, "badvalue",
            "wrong # args: should be \"::machteld::LuaCell popen ?nstates? ?memcap_mb?\"");
    }
    if (objc >= 3 && Tcl_GetWideIntFromObj(interp, objv[2], &n) != TCL_OK) {
        return TCL_ERROR;
    }
    if (objc == 4 && Tcl_GetWideIntFromObj(interp, objv[3], &cap_mb) != TCL_OK) {
        return TCL_ERROR;
    }
    if (cap_mb <= 0) {
        return mlua_error(interp, "badvalue", "memcap_mb must be positive");
    }
    if (n <= 0) {
        SYSTEM_INFO si;
        GetSystemInfo(&si);
        n = (Tcl_WideInt)si.dwNumberOfProcessors;
        if (n > 16) { n = 16; }
    }
    if (n > MLUA_MAX_POOL) { n = MLUA_MAX_POOL; }
    mlua_close_pool(st);
    for (int i = 0; i < (int)n; i++) {
        st->pool[i].L = mlua_new_state(&st->pool[i].alloc, cap_mb);
        if (st->pool[i].L == NULL) {
            mlua_close_pool(st);
            return mlua_error(interp, "state", "pool state creation failed");
        }
    }
    st->pool_n = (int)n;
    Tcl_SetObjResult(interp, Tcl_NewWideIntObj(n));
    return TCL_OK;
}

static int
mlua_pmarshal(mlua_state *st, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    if (objc != 4) {
        return mlua_error(interp, "badvalue",
            "wrong # args: should be \"::machteld::LuaCell pmarshal rows types\"");
    }
    if (mlua_need_pool(st, interp) != TCL_OK) {
        return TCL_ERROR;
    }
    Tcl_Size nrows, ntypes;
    Tcl_Obj **rows, **types;
    if (Tcl_ListObjGetElements(interp, objv[2], &nrows, &rows) != TCL_OK ||
        Tcl_ListObjGetElements(interp, objv[3], &ntypes, &types) != TCL_OK) {
        return TCL_ERROR;
    }
    Tcl_Size base = nrows / st->pool_n;
    Tcl_Size extra = nrows % st->pool_n;
    Tcl_Size off = 0;
    Tcl_Obj *sizes = Tcl_NewListObj(0, NULL);
    for (int i = 0; i < st->pool_n; i++) {
        Tcl_Size take = base + ((Tcl_Size)i < extra ? 1 : 0);
        if (mlua_load_rows(interp, st->pool[i].L, rows + off, take,
                           types, ntypes) != TCL_OK) {
            Tcl_BounceRefCount(sizes);
            return TCL_ERROR;
        }
        Tcl_ListObjAppendElement(interp, sizes, Tcl_NewWideIntObj(take));
        off += take;
    }
    Tcl_SetObjResult(interp, sizes);
    return TCL_OK;
}

static int
mlua_pcompile(mlua_state *st, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    if (objc != 4) {
        return mlua_error(interp, "badvalue",
            "wrong # args: should be \"::machteld::LuaCell pcompile name luasrc\"");
    }
    if (mlua_need_pool(st, interp) != TCL_OK) {
        return TCL_ERROR;
    }
    for (int i = 0; i < st->pool_n; i++) {
        char where[32];
        snprintf(where, sizeof(where), " in slot %d", i);
        if (mlua_compile_into(interp, st->pool[i].L, objv[2], objv[3],
                              where) != TCL_OK) {
            return TCL_ERROR;
        }
    }
    Tcl_SetObjResult(interp, objv[2]);
    return TCL_OK;
}

static int
mlua_pcall(mlua_state *st, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    if (objc != 3) {
        return mlua_error(interp, "badvalue",
            "wrong # args: should be \"::machteld::LuaCell pcall name\"");
    }
    if (mlua_need_pool(st, interp) != TCL_OK) {
        return TCL_ERROR;
    }
    const char *fname = Tcl_GetString(objv[2]);
    mlua_work work[MLUA_MAX_POOL];
    HANDLE threads[MLUA_MAX_POOL];
    for (int i = 0; i < st->pool_n; i++) {
        work[i].L = st->pool[i].L;
        work[i].fname = fname;
        work[i].result = 0;
        work[i].failed = 0;
        work[i].err[0] = '\0';
        uintptr_t h = _beginthreadex(NULL, 0, mlua_worker, &work[i], 0, NULL);
        if (h == 0) {
            for (int k = 0; k < i; k++) {
                WaitForSingleObject(threads[k], INFINITE);
                CloseHandle(threads[k]);
            }
            return mlua_error(interp, "thread", "worker thread creation failed");
        }
        threads[i] = (HANDLE)h;
    }
    WaitForMultipleObjects((DWORD)st->pool_n, threads, TRUE, INFINITE);
    for (int i = 0; i < st->pool_n; i++) {
        CloseHandle(threads[i]);
    }
    for (int i = 0; i < st->pool_n; i++) {
        if (work[i].failed) {
            return mlua_errorf(interp, "call", Tcl_ObjPrintf(
                "machteld: parallel call failed in slot %d: %s",
                i, work[i].err));
        }
    }
    Tcl_Obj *res = Tcl_NewListObj(0, NULL);
    for (int i = 0; i < st->pool_n; i++) {
        Tcl_ListObjAppendElement(interp, res,
            Tcl_NewWideIntObj(work[i].result));
    }
    Tcl_SetObjResult(interp, res);
    return TCL_OK;
}

static int
LuaCellCmd(void *client_data, Tcl_Interp *interp, int objc,
           Tcl_Obj *const objv[])
{
    static const char *const subs[] = {
        "open", "close", "compile", "loadtable", "call", "memused",
        "popen", "pclose", "pmarshal", "pcompile", "pcall", NULL
    };
    enum {
        SUB_OPEN, SUB_CLOSE, SUB_COMPILE, SUB_LOADTABLE, SUB_CALL,
        SUB_MEMUSED, SUB_POPEN, SUB_PCLOSE, SUB_PMARSHAL, SUB_PCOMPILE,
        SUB_PCALL
    };
    mlua_state *st = (mlua_state *)client_data;
    int sub;

    if (objc < 2) {
        return mlua_error(interp, "badvalue",
            "wrong # args: should be \"::machteld::LuaCell subcommand ?arg ...?\"");
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", 0,
                            &sub) != TCL_OK) {
        Tcl_SetErrorCode(interp, "MACHTELD", "MACHT", "badvalue", (char *)NULL);
        return TCL_ERROR;
    }
    switch (sub) {
    case SUB_OPEN:
        return mlua_open(st, interp, objc, objv);
    case SUB_CLOSE:
        mlua_close_cell(st);
        return TCL_OK;
    case SUB_COMPILE:
        if (objc != 4) {
            return mlua_error(interp, "badvalue",
                "wrong # args: should be \"::machteld::LuaCell compile name luasrc\"");
        }
        if (mlua_need_cell(st, interp) != TCL_OK) {
            return TCL_ERROR;
        }
        if (mlua_compile_into(interp, st->cell.L, objv[2], objv[3],
                              "") != TCL_OK) {
            return TCL_ERROR;
        }
        Tcl_SetObjResult(interp, objv[2]);
        return TCL_OK;
    case SUB_LOADTABLE: {
        if (objc != 4) {
            return mlua_error(interp, "badvalue",
                "wrong # args: should be \"::machteld::LuaCell loadtable rows types\"");
        }
        if (mlua_need_cell(st, interp) != TCL_OK) {
            return TCL_ERROR;
        }
        Tcl_Size nrows, ntypes;
        Tcl_Obj **rows, **types;
        if (Tcl_ListObjGetElements(interp, objv[2], &nrows, &rows) != TCL_OK ||
            Tcl_ListObjGetElements(interp, objv[3], &ntypes, &types) != TCL_OK) {
            return TCL_ERROR;
        }
        if (mlua_load_rows(interp, st->cell.L, rows, nrows, types,
                           ntypes) != TCL_OK) {
            return TCL_ERROR;
        }
        Tcl_SetObjResult(interp, Tcl_NewWideIntObj((Tcl_WideInt)nrows));
        return TCL_OK;
    }
    case SUB_CALL:
        return mlua_call(st, interp, objc, objv);
    case SUB_MEMUSED:
        Tcl_SetObjResult(interp,
            Tcl_NewWideIntObj((Tcl_WideInt)st->cell.alloc.used));
        return TCL_OK;
    case SUB_POPEN:
        return mlua_popen(st, interp, objc, objv);
    case SUB_PCLOSE:
        mlua_close_pool(st);
        return TCL_OK;
    case SUB_PMARSHAL:
        return mlua_pmarshal(st, interp, objc, objv);
    case SUB_PCOMPILE:
        return mlua_pcompile(st, interp, objc, objv);
    case SUB_PCALL:
        return mlua_pcall(st, interp, objc, objv);
    }
    return mlua_error(interp, "badvalue", "unreachable subcommand");
}

static void
mlua_delete(void *client_data)
{
    mlua_state *st = (mlua_state *)client_data;
    mlua_close_cell(st);
    mlua_close_pool(st);
    free(st);
}

int
Machteldlua_Init(Tcl_Interp *interp)
{
    mlua_state *st = (mlua_state *)calloc(1, sizeof(mlua_state));
    if (st == NULL) {
        return mlua_error(interp, "state", "cannot allocate lua module state");
    }
    if (Tcl_CreateObjCommand(interp, "::machteld::LuaCell", LuaCellCmd, st,
                             mlua_delete) == NULL) {
        free(st);
        return mlua_error(interp, "state",
            "cannot register the LuaCell primitive");
    }
    return TCL_OK;
}

#endif /* MACHTELD_LUA */
