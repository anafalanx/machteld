/*
 * store.c -- machteld's purpose-built SQLite bridge for the C tier.
 *
 * The SQLite amalgamation is compiled statically into every host. This bridge
 * deliberately exposes a narrow key/value API rather than a generic SQL command.
 *
 *   ::machteld::store open ?path?     open (default :memory:); create the schema
 *   ::machteld::store put key value   upsert
 *   ::machteld::store get key         bytearray value; notfound if absent
 *   ::machteld::store keys            sorted list of keys
 *   ::machteld::store del key         delete
 *   ::machteld::store close           close the database
 *   ::machteld::store version         sqlite3 library version
 *
 * Registered by Machteldstore_Init, which the host calls behind
 * MACHTELD_STATIC_SQLITE.
 */

#include <stdlib.h>
#include <string.h>
#include "machteld.h"
#include "sqlite3.h"

typedef struct {
    sqlite3 *db;
} StoreCtx;

/* SQLite's message is diagnostic and may change; callers trap the stable code. */
static int fail_code(Tcl_Interp *interp, const char *code, const char *msg) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg ? msg : "error", -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "STORE", code, (char *)NULL);
    return TCL_ERROR;
}

static int fail(Tcl_Interp *interp, const char *msg) {
    return fail_code(interp, "sqlite", msg);
}

static int needDb(Tcl_Interp *interp, StoreCtx *ctx) {
    if (ctx->db == NULL) {
        fail_code(interp, "notopen", "store not open (::machteld::store open ?path?)");
        return 0;
    }
    return 1;
}

/* Bytearrays are stored verbatim. Other values use their UTF-8 string
 * representation, so ordinary Unicode text remains convenient. */
static const unsigned char *store_value_bytes(Tcl_Obj *obj, Tcl_Size *length) {
    const Tcl_ObjType *type = obj->typePtr;
    if (type != NULL && type->name != NULL &&
            strcmp(type->name, "bytearray") == 0) {
        return Tcl_GetBytesFromObj(NULL, obj, length);
    }
    return (const unsigned char *)Tcl_GetStringFromObj(obj, length);
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
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", TCL_EXACT, &idx) != TCL_OK) {
        return TCL_ERROR;
    }

    switch (idx) {
    case VERSION:
        if (objc != 2) { Tcl_WrongNumArgs(interp, 2, objv, ""); return TCL_ERROR; }
        Tcl_SetObjResult(interp, Tcl_NewStringObj(sqlite3_libversion(), -1));
        return TCL_OK;

    case OPEN: {
        if (objc < 2 || objc > 3) {
            Tcl_WrongNumArgs(interp, 2, objv, "?path?");
            return TCL_ERROR;
        }
        const char *path = ":memory:";
        if (objc >= 3) {
            Tcl_Size pathLen;
            path = Tcl_GetStringFromObj(objv[2], &pathLen);
            if (pathLen == 0 || memchr(path, '\0', (size_t)pathLen) != NULL) {
                return fail_code(interp, "badvalue",
                    "store path must be a non-empty string without NUL bytes");
            }
        }
        if (ctx->db) { sqlite3_close(ctx->db); ctx->db = NULL; }
        if (sqlite3_open(path, &ctx->db) != SQLITE_OK) {
            int r = fail(interp, sqlite3_errmsg(ctx->db));
            sqlite3_close(ctx->db);
            ctx->db = NULL;
            return r;
        }
        if (sqlite3_busy_timeout(ctx->db, 5000) != SQLITE_OK) {
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
            sqlite3_close(ctx->db);
            ctx->db = NULL;
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
        const unsigned char *v = store_value_bytes(objv[3], &vlen);
        int rc = sqlite3_bind_text64(st, 1, k, (sqlite3_uint64)klen,
                                     SQLITE_TRANSIENT, SQLITE_UTF8);
        if (rc == SQLITE_OK) {
            rc = sqlite3_bind_blob64(st, 2, v, (sqlite3_uint64)vlen,
                                     SQLITE_TRANSIENT);
        }
        if (rc != SQLITE_OK) {
            sqlite3_finalize(st);
            return fail(interp, sqlite3_errmsg(ctx->db));
        }
        rc = sqlite3_step(st);
        int frc = sqlite3_finalize(st);
        if (rc != SQLITE_DONE || frc != SQLITE_OK) {
            return fail(interp, sqlite3_errmsg(ctx->db));
        }
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
        int rc = sqlite3_bind_text64(st, 1, k, (sqlite3_uint64)klen,
                                     SQLITE_TRANSIENT, SQLITE_UTF8);
        if (rc != SQLITE_OK) {
            sqlite3_finalize(st);
            return fail(interp, sqlite3_errmsg(ctx->db));
        }
        Tcl_Obj *res = NULL;
        rc = sqlite3_step(st);
        if (rc == SQLITE_ROW) {
            const unsigned char *val = sqlite3_column_blob(st, 0);
            int n = sqlite3_column_bytes(st, 0);
            res = Tcl_NewByteArrayObj(
                val ? val : (const unsigned char *)"", n);
        }
        int frc = sqlite3_finalize(st);
        if (rc == SQLITE_DONE) {
            return fail_code(interp, "notfound", "store key not found");
        }
        if (rc != SQLITE_ROW || frc != SQLITE_OK) {
            return fail(interp, sqlite3_errmsg(ctx->db));
        }
        Tcl_SetObjResult(interp, res);
        return TCL_OK;
    }

    case KEYS: {
        if (objc != 2) { Tcl_WrongNumArgs(interp, 2, objv, ""); return TCL_ERROR; }
        if (!needDb(interp, ctx)) return TCL_ERROR;
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ctx->db, "SELECT key FROM kv ORDER BY key;",
                -1, &st, NULL) != SQLITE_OK) {
            return fail(interp, sqlite3_errmsg(ctx->db));
        }
        Tcl_Obj *list = Tcl_NewListObj(0, NULL);
        int rc;
        while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
            const char *k = (const char *)sqlite3_column_text(st, 0);
            int n = sqlite3_column_bytes(st, 0);
            Tcl_ListObjAppendElement(interp, list, Tcl_NewStringObj(k ? k : "", n));
        }
        int frc = sqlite3_finalize(st);
        if (rc != SQLITE_DONE || frc != SQLITE_OK) {
            return fail(interp, sqlite3_errmsg(ctx->db));
        }
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
        int rc = sqlite3_bind_text64(st, 1, k, (sqlite3_uint64)klen,
                                     SQLITE_TRANSIENT, SQLITE_UTF8);
        if (rc == SQLITE_OK) rc = sqlite3_step(st);
        int frc = sqlite3_finalize(st);
        if (rc != SQLITE_DONE || frc != SQLITE_OK) {
            return fail(interp, sqlite3_errmsg(ctx->db));
        }
        Tcl_SetObjResult(interp, Tcl_NewWideIntObj(sqlite3_changes(ctx->db)));
        return TCL_OK;
    }

    case CLOSE:
        if (objc != 2) { Tcl_WrongNumArgs(interp, 2, objv, ""); return TCL_ERROR; }
        if (ctx->db) {
            int rc = sqlite3_close(ctx->db);
            if (rc != SQLITE_OK) return fail(interp, sqlite3_errmsg(ctx->db));
            ctx->db = NULL;
        }
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
    if (ctx == NULL) {
        return fail_code(interp, "sqlite", "out of memory creating store");
    }
    ctx->db = NULL;
    if (Tcl_Eval(interp, "namespace eval ::machteld {}") != TCL_OK) {
        free(ctx);
        return TCL_ERROR;
    }
    if (Tcl_CreateObjCommand(interp, "::machteld::store", StoreCmd, ctx,
                             StoreDelete) == NULL) {
        free(ctx);
        return TCL_ERROR;
    }
    if (Tcl_PkgProvide(interp, "machteld::store", MACHTELD_VERSION) != TCL_OK) {
        Tcl_DeleteCommand(interp, "::machteld::store");
        return TCL_ERROR;
    }
    return TCL_OK;
}
