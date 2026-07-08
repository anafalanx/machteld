/*
 * store.c -- machteld's purpose-built SQLite bridge for the C tier.
 *
 * The SQLite amalgamation (sqlite3.c) is compiled statically into the host; this
 * file uses it through the C API and exposes a small, CURATED Tcl command --
 * deliberately NOT the generic `sqlite3` command. SQLite is a native capability
 * the C part owns; Tcl gets a narrow key/value interface, never raw SQL. Modeled
 * on drenn's C bridge; carried over from sturm.
 *
 *   ::machteld::store open ?path?     open (default :memory:); create the schema
 *   ::machteld::store put key value   upsert
 *   ::machteld::store get key         value, or "" if absent
 *   ::machteld::store keys            sorted list of keys
 *   ::machteld::store del key         delete
 *   ::machteld::store close           close the database
 *   ::machteld::store version         sqlite3 library version
 *
 * Registered by Machteldstore_Init, which the host calls behind
 * MACHTELD_STATIC_SQLITE.
 */

#include <stdlib.h>
#include <tcl.h>
#include "sqlite3.h"

typedef struct {
    sqlite3 *db;
} StoreCtx;

static int fail(Tcl_Interp *interp, const char *msg) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg ? msg : "error", -1));
    return TCL_ERROR;
}

static int needDb(Tcl_Interp *interp, StoreCtx *ctx) {
    if (ctx->db == NULL) {
        Tcl_SetObjResult(interp,
            Tcl_NewStringObj("store not open (::machteld::store open ?path?)", -1));
        return 0;
    }
    return 1;
}

static int StoreCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    StoreCtx *ctx = (StoreCtx *)cd;
    static const char *const subs[] = {
        "open", "put", "get", "keys", "del", "close", "version", NULL
    };
    enum { OPEN, PUT, GET, KEYS, DEL, CLOSE, VERSION };
    int idx;

    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "subcommand ?arg ...?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", 0, &idx) != TCL_OK) {
        return TCL_ERROR;
    }

    switch (idx) {
    case VERSION:
        Tcl_SetObjResult(interp, Tcl_NewStringObj(sqlite3_libversion(), -1));
        return TCL_OK;

    case OPEN: {
        const char *path = (objc >= 3) ? Tcl_GetString(objv[2]) : ":memory:";
        if (ctx->db) { sqlite3_close(ctx->db); ctx->db = NULL; }
        if (sqlite3_open(path, &ctx->db) != SQLITE_OK) {
            int r = fail(interp, sqlite3_errmsg(ctx->db));
            sqlite3_close(ctx->db);
            ctx->db = NULL;
            return r;
        }
        char *err = NULL;
        if (sqlite3_exec(ctx->db,
                "CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID;",
                NULL, NULL, &err) != SQLITE_OK) {
            int r = fail(interp, err);
            sqlite3_free(err);
            return r;
        }
        return TCL_OK;
    }

    case PUT: {
        if (objc != 4) { Tcl_WrongNumArgs(interp, 2, objv, "key value"); return TCL_ERROR; }
        if (!needDb(interp, ctx)) return TCL_ERROR;
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ctx->db,
                "INSERT INTO kv(key,value) VALUES(?1,?2) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                -1, &st, NULL) != SQLITE_OK) {
            return fail(interp, sqlite3_errmsg(ctx->db));
        }
        Tcl_Size klen, vlen;
        const char *k = Tcl_GetStringFromObj(objv[2], &klen);
        const char *v = Tcl_GetStringFromObj(objv[3], &vlen);
        sqlite3_bind_text(st, 1, k, (int)klen, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, v, (int)vlen, SQLITE_TRANSIENT);
        int rc = sqlite3_step(st);
        sqlite3_finalize(st);
        if (rc != SQLITE_DONE) return fail(interp, sqlite3_errmsg(ctx->db));
        return TCL_OK;
    }

    case GET: {
        if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "key"); return TCL_ERROR; }
        if (!needDb(interp, ctx)) return TCL_ERROR;
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ctx->db, "SELECT value FROM kv WHERE key=?1;",
                -1, &st, NULL) != SQLITE_OK) {
            return fail(interp, sqlite3_errmsg(ctx->db));
        }
        Tcl_Size klen;
        const char *k = Tcl_GetStringFromObj(objv[2], &klen);
        sqlite3_bind_text(st, 1, k, (int)klen, SQLITE_TRANSIENT);
        Tcl_Obj *res;
        if (sqlite3_step(st) == SQLITE_ROW) {
            const char *val = (const char *)sqlite3_column_text(st, 0);
            int n = sqlite3_column_bytes(st, 0);
            res = Tcl_NewStringObj(val ? val : "", n);
        } else {
            res = Tcl_NewStringObj("", 0);
        }
        sqlite3_finalize(st);
        Tcl_SetObjResult(interp, res);
        return TCL_OK;
    }

    case KEYS: {
        if (!needDb(interp, ctx)) return TCL_ERROR;
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ctx->db, "SELECT key FROM kv ORDER BY key;",
                -1, &st, NULL) != SQLITE_OK) {
            return fail(interp, sqlite3_errmsg(ctx->db));
        }
        Tcl_Obj *list = Tcl_NewListObj(0, NULL);
        while (sqlite3_step(st) == SQLITE_ROW) {
            const char *k = (const char *)sqlite3_column_text(st, 0);
            int n = sqlite3_column_bytes(st, 0);
            Tcl_ListObjAppendElement(interp, list, Tcl_NewStringObj(k ? k : "", n));
        }
        sqlite3_finalize(st);
        Tcl_SetObjResult(interp, list);
        return TCL_OK;
    }

    case DEL: {
        if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "key"); return TCL_ERROR; }
        if (!needDb(interp, ctx)) return TCL_ERROR;
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ctx->db, "DELETE FROM kv WHERE key=?1;",
                -1, &st, NULL) != SQLITE_OK) {
            return fail(interp, sqlite3_errmsg(ctx->db));
        }
        Tcl_Size klen;
        const char *k = Tcl_GetStringFromObj(objv[2], &klen);
        sqlite3_bind_text(st, 1, k, (int)klen, SQLITE_TRANSIENT);
        sqlite3_step(st);
        sqlite3_finalize(st);
        return TCL_OK;
    }

    case CLOSE:
        if (ctx->db) { sqlite3_close(ctx->db); ctx->db = NULL; }
        return TCL_OK;
    }
    return TCL_OK;
}

static void StoreDelete(void *cd) {
    StoreCtx *ctx = (StoreCtx *)cd;
    if (ctx->db) sqlite3_close(ctx->db);
    free(ctx);
}

/* Called by the host (behind MACHTELD_STATIC_SQLITE) to register the bridge. */
int Machteldstore_Init(Tcl_Interp *interp) {
    StoreCtx *ctx = (StoreCtx *)malloc(sizeof(StoreCtx));
    if (ctx == NULL) return TCL_ERROR;
    ctx->db = NULL;
    Tcl_Eval(interp, "namespace eval ::machteld {}");
    Tcl_CreateObjCommand(interp, "::machteld::store", StoreCmd, ctx, StoreDelete);
    Tcl_PkgProvide(interp, "machteld::store", "0.1");
    return TCL_OK;
}
