/*
 * journal.c -- what the front door did, in SQLite.
 *
 * A front door sees every process the workspace starts, which nothing else
 * does: a shell records the line you typed, not what it resolved to, how long it
 * took, or whether it was killed. This keeps that record.
 *
 *   ::machteld::journal open path      open (creating), set the pragmas, ensure the schema
 *   ::machteld::journal add dict       a process started -> its row id
 *   ::machteld::journal done id st ex  that process ended
 *   ::machteld::journal rows ?filters? matching rows, newest first
 *   ::machteld::journal prune ms       drop rows older than a cutoff -> rows removed
 *   ::machteld::journal stats          counts by status, and the row total
 *   ::machteld::journal close
 *
 * A SEPARATE CONNECTION FROM `store`, ON PURPOSE. `store` is a key/value surface
 * over one database a script chose; the journal is the front door's own record,
 * in its own file, and the two must not be able to evict each other by both
 * being "the" database. Same reason it is a separate verb rather than a table
 * inside `store`.
 *
 * AND STILL NO RAW SQL. store.c says it plainly -- "Tcl gets a narrow key/value
 * interface, never raw SQL" -- and that refusal is not overturned here just
 * because a second caller wants a database. Every statement below is written
 * out, and every value a caller supplies is BOUND rather than pasted, so a tool
 * name containing a quote is a tool name and never a fragment of a query. The
 * queries the journal needs are known in advance; when the live view wants one
 * more, it becomes another filter here rather than a SQL console in Tcl.
 *
 * Registered by Machteldjournal_Init behind MACHTELD_JOURNAL.
 */
#include <stdlib.h>
#include <string.h>
#include <tcl.h>
#include "sqlite3.h"

typedef struct {
    sqlite3 *db;
} JournalCtx;

static int fail_code(Tcl_Interp *interp, const char *code, const char *msg) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg ? msg : "error", -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "JOURNAL", code, (char *)NULL);
    return TCL_ERROR;
}

static int fail_sqlite(Tcl_Interp *interp, JournalCtx *ctx) {
    return fail_code(interp, "sqlite", sqlite3_errmsg(ctx->db));
}

static int need_db(Tcl_Interp *interp, JournalCtx *ctx) {
    if (ctx->db == NULL) return fail_code(interp, "notopen", "journal is not open");
    return TCL_OK;
}

/* The schema, and the pragmas that make it survivable.
 *
 * WAL because every `mt <name>` is a SEPARATE PROCESS: the journal is
 * multi-writer by construction, not by accident. NORMAL because fsync was
 * measured to be the entire throughput story (118/sec -> 16,129/sec) and it
 * still loses at most the last commit on a power cut. busy_timeout because two
 * front doors starting at once should wait for each other rather than fail. */
static const char *SCHEMA =
    "PRAGMA journal_mode = WAL;"
    "PRAGMA synchronous = NORMAL;"
    "CREATE TABLE IF NOT EXISTS run ("
    "  id INTEGER PRIMARY KEY,"
    "  session TEXT NOT NULL,"
    "  parent INTEGER,"
    "  started INTEGER NOT NULL,"
    "  ended INTEGER,"
    "  ms INTEGER,"
    "  name TEXT NOT NULL,"
    "  kind TEXT NOT NULL,"
    "  exe TEXT NOT NULL,"
    "  argv TEXT NOT NULL,"
    "  cwd TEXT NOT NULL,"
    "  project TEXT,"
    "  pid INTEGER,"
    "  status TEXT,"
    "  exit INTEGER"
    ");"
    "CREATE INDEX IF NOT EXISTS run_started ON run(started DESC);"
    "CREATE INDEX IF NOT EXISTS run_project ON run(project, started DESC);"
    "CREATE INDEX IF NOT EXISTS run_name ON run(name, started DESC);"
    "CREATE INDEX IF NOT EXISTS run_live ON run(ended) WHERE ended IS NULL;";

/* Every column of `run`, in one place: the row reader and the INSERT both use
 * it, so a column added to the schema cannot be forgotten by one of them. */
static const char *COLS[] = { "id", "session", "parent", "started", "ended", "ms",
                              "name", "kind", "exe", "argv", "cwd", "project",
                              "pid", "status", "exit", NULL };

/* One row as a dict. A NULL column is the EMPTY STRING rather than 0: `ended`
 * being absent means "still running", and rendering that as 0 would read as
 * "ended at the epoch" -- the same rule `ps` follows for a process it may not
 * inspect. */
static Tcl_Obj *row_dict(Tcl_Interp *interp, sqlite3_stmt *st) {
    Tcl_Obj *d = Tcl_NewDictObj();
    int n = sqlite3_column_count(st);
    for (int i = 0; i < n; i++) {
        const char *cname = sqlite3_column_name(st, i);
        Tcl_Obj *v;
        if (sqlite3_column_type(st, i) == SQLITE_NULL) {
            v = Tcl_NewStringObj("", -1);
        } else if (sqlite3_column_type(st, i) == SQLITE_INTEGER) {
            v = Tcl_NewWideIntObj(sqlite3_column_int64(st, i));
        } else {
            const char *t = (const char *)sqlite3_column_text(st, i);
            v = Tcl_NewStringObj(t ? t : "", sqlite3_column_bytes(st, i));
        }
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj(cname, -1), v);
    }
    return d;
}

static int dict_str(Tcl_Interp *interp, Tcl_Obj *d, const char *key, const char **out) {
    Tcl_Obj *v = NULL;
    Tcl_Obj *k = Tcl_NewStringObj(key, -1);
    Tcl_IncrRefCount(k);
    int rc = Tcl_DictObjGet(interp, d, k, &v);
    Tcl_DecrRefCount(k);
    if (rc != TCL_OK) return TCL_ERROR;
    *out = (v == NULL) ? NULL : Tcl_GetString(v);
    return TCL_OK;
}

static int JournalCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    JournalCtx *ctx = (JournalCtx *)cd;
    static const char *const subs[] = {
        "open", "add", "done", "rows", "prune", "stats", "close", NULL
    };
    enum { OPEN, ADD, DONE, ROWS, PRUNE, STATS, CLOSE };
    int idx;

    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "subcommand ?arg ...?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", 0, &idx) != TCL_OK) return TCL_ERROR;

    if (idx == OPEN) {
        if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "path"); return TCL_ERROR; }
        if (ctx->db != NULL) { sqlite3_close(ctx->db); ctx->db = NULL; }
        const char *path = Tcl_GetString(objv[2]);
        if (sqlite3_open(path, &ctx->db) != SQLITE_OK) {
            int rc = fail_code(interp, "sqlite", sqlite3_errmsg(ctx->db));
            sqlite3_close(ctx->db);
            ctx->db = NULL;
            return rc;
        }
        sqlite3_busy_timeout(ctx->db, 5000);
        char *emsg = NULL;
        if (sqlite3_exec(ctx->db, SCHEMA, NULL, NULL, &emsg) != SQLITE_OK) {
            int rc = fail_code(interp, "sqlite", emsg ? emsg : "cannot create the schema");
            sqlite3_free(emsg);
            sqlite3_close(ctx->db);
            ctx->db = NULL;
            return rc;
        }
        return TCL_OK;
    }

    if (idx == CLOSE) {
        if (objc != 2) { Tcl_WrongNumArgs(interp, 2, objv, ""); return TCL_ERROR; }
        if (ctx->db != NULL) { sqlite3_close(ctx->db); ctx->db = NULL; }
        return TCL_OK;
    }

    if (need_db(interp, ctx) != TCL_OK) return TCL_ERROR;

    if (idx == ADD) {
        if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "dict"); return TCL_ERROR; }
        const char *session = NULL, *name = NULL, *kind = NULL, *exe = NULL;
        const char *argvj = NULL, *cwd = NULL, *project = NULL, *parent = NULL, *pid = NULL;
        if (dict_str(interp, objv[2], "session", &session) != TCL_OK
            || dict_str(interp, objv[2], "name", &name) != TCL_OK
            || dict_str(interp, objv[2], "kind", &kind) != TCL_OK
            || dict_str(interp, objv[2], "exe", &exe) != TCL_OK
            || dict_str(interp, objv[2], "argv", &argvj) != TCL_OK
            || dict_str(interp, objv[2], "cwd", &cwd) != TCL_OK
            || dict_str(interp, objv[2], "project", &project) != TCL_OK
            || dict_str(interp, objv[2], "parent", &parent) != TCL_OK
            || dict_str(interp, objv[2], "pid", &pid) != TCL_OK) return TCL_ERROR;
        if (session == NULL || name == NULL || kind == NULL) {
            return fail_code(interp, "usage", "a journal row needs at least session, name and kind");
        }
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ctx->db,
                "INSERT INTO run (session,parent,started,name,kind,exe,argv,cwd,project,pid,status)"
                " VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,'running');", -1, &st, NULL) != SQLITE_OK) {
            return fail_sqlite(interp, ctx);
        }
        sqlite3_bind_text(st, 1, session, -1, SQLITE_TRANSIENT);
        if (parent && *parent) sqlite3_bind_int64(st, 2, (sqlite3_int64)atoll(parent));
        else                   sqlite3_bind_null(st, 2);
        Tcl_WideInt now;
        Tcl_Obj *clk = Tcl_NewStringObj("clock milliseconds", -1);
        Tcl_IncrRefCount(clk);
        if (Tcl_EvalObjEx(interp, clk, TCL_EVAL_GLOBAL) != TCL_OK
            || Tcl_GetWideIntFromObj(interp, Tcl_GetObjResult(interp), &now) != TCL_OK) {
            Tcl_DecrRefCount(clk); sqlite3_finalize(st);
            return fail_code(interp, "sqlite", "cannot read the clock");
        }
        Tcl_DecrRefCount(clk);
        Tcl_ResetResult(interp);
        sqlite3_bind_int64(st, 3, (sqlite3_int64)now);
        sqlite3_bind_text(st, 4, name, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 5, kind, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 6, exe ? exe : "", -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 7, argvj ? argvj : "", -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 8, cwd ? cwd : "", -1, SQLITE_TRANSIENT);
        if (project && *project) sqlite3_bind_text(st, 9, project, -1, SQLITE_TRANSIENT);
        else                     sqlite3_bind_null(st, 9);
        if (pid && *pid) sqlite3_bind_int64(st, 10, (sqlite3_int64)atoll(pid));
        else             sqlite3_bind_null(st, 10);
        if (sqlite3_step(st) != SQLITE_DONE) {
            int rc = fail_sqlite(interp, ctx);
            sqlite3_finalize(st);
            return rc;
        }
        sqlite3_finalize(st);
        Tcl_SetObjResult(interp, Tcl_NewWideIntObj((Tcl_WideInt)sqlite3_last_insert_rowid(ctx->db)));
        return TCL_OK;
    }

    if (idx == DONE) {
        /* `ms` is computed from the row's own `started` rather than passed in:
         * the caller would have to have kept it, and a duration derived from two
         * different clocks is not a duration. */
        if (objc != 5) { Tcl_WrongNumArgs(interp, 2, objv, "id status exit"); return TCL_ERROR; }
        Tcl_WideInt id, ex;
        if (Tcl_GetWideIntFromObj(interp, objv[2], &id) != TCL_OK) return TCL_ERROR;
        const char *status = Tcl_GetString(objv[3]);
        const char *exs = Tcl_GetString(objv[4]);
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ctx->db,
                "UPDATE run SET ended = ?1, ms = ?1 - started, status = ?2, exit = ?3"
                " WHERE id = ?4;", -1, &st, NULL) != SQLITE_OK) {
            return fail_sqlite(interp, ctx);
        }
        Tcl_WideInt now;
        Tcl_Obj *clk = Tcl_NewStringObj("clock milliseconds", -1);
        Tcl_IncrRefCount(clk);
        if (Tcl_EvalObjEx(interp, clk, TCL_EVAL_GLOBAL) != TCL_OK
            || Tcl_GetWideIntFromObj(interp, Tcl_GetObjResult(interp), &now) != TCL_OK) {
            Tcl_DecrRefCount(clk); sqlite3_finalize(st);
            return fail_code(interp, "sqlite", "cannot read the clock");
        }
        Tcl_DecrRefCount(clk);
        Tcl_ResetResult(interp);
        sqlite3_bind_int64(st, 1, (sqlite3_int64)now);
        sqlite3_bind_text(st, 2, status, -1, SQLITE_TRANSIENT);
        if (*exs) { ex = 0; Tcl_GetWideIntFromObj(NULL, objv[4], &ex); sqlite3_bind_int64(st, 3, (sqlite3_int64)ex); }
        else      { sqlite3_bind_null(st, 3); }
        sqlite3_bind_int64(st, 4, (sqlite3_int64)id);
        if (sqlite3_step(st) != SQLITE_DONE) {
            int rc = fail_sqlite(interp, ctx);
            sqlite3_finalize(st);
            return rc;
        }
        sqlite3_finalize(st);
        Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_changes(ctx->db)));
        return TCL_OK;
    }

    if (idx == ROWS) {
        /* The filters are ANDed, and every value is BOUND. The clause text is
         * assembled from a fixed set of fragments -- never from a caller's
         * string -- so there is nothing here for a tool name to escape into. */
        char sql[512];
        strcpy(sql, "SELECT * FROM run WHERE 1=1");
        const char *name = NULL, *project = NULL;
        Tcl_WideInt since = 0, limit = 100;
        int live = 0, failed = 0, hasSince = 0;
        for (int i = 2; i < objc; i++) {
            const char *a = Tcl_GetString(objv[i]);
            if (strcmp(a, "-live") == 0)   { live = 1; continue; }
            if (strcmp(a, "-failed") == 0) { failed = 1; continue; }
            if (i + 1 >= objc) return fail_code(interp, "usage", "option needs a value");
            if (strcmp(a, "-name") == 0)         { name = Tcl_GetString(objv[++i]); continue; }
            if (strcmp(a, "-project") == 0)      { project = Tcl_GetString(objv[++i]); continue; }
            if (strcmp(a, "-since") == 0)        {
                if (Tcl_GetWideIntFromObj(interp, objv[++i], &since) != TCL_OK) return TCL_ERROR;
                hasSince = 1; continue;
            }
            if (strcmp(a, "-limit") == 0)        {
                if (Tcl_GetWideIntFromObj(interp, objv[++i], &limit) != TCL_OK) return TCL_ERROR;
                continue;
            }
            return fail_code(interp, "usage", "unknown option");
        }
        if (live)     strcat(sql, " AND ended IS NULL");
        if (failed)   strcat(sql, " AND status IS NOT NULL AND status <> 'ok'");
        if (name)     strcat(sql, " AND name = ?1");
        if (project)  strcat(sql, " AND project = ?2");
        if (hasSince) strcat(sql, " AND started >= ?3");
        strcat(sql, " ORDER BY started DESC LIMIT ?4;");

        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ctx->db, sql, -1, &st, NULL) != SQLITE_OK) return fail_sqlite(interp, ctx);
        if (name)     sqlite3_bind_text(st, 1, name, -1, SQLITE_TRANSIENT);
        if (project)  sqlite3_bind_text(st, 2, project, -1, SQLITE_TRANSIENT);
        if (hasSince) sqlite3_bind_int64(st, 3, (sqlite3_int64)since);
        sqlite3_bind_int64(st, 4, (sqlite3_int64)limit);

        Tcl_Obj *out = Tcl_NewListObj(0, NULL);
        int rc;
        while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
            Tcl_ListObjAppendElement(interp, out, row_dict(interp, st));
        }
        sqlite3_finalize(st);
        if (rc != SQLITE_DONE) return fail_sqlite(interp, ctx);
        Tcl_SetObjResult(interp, out);
        return TCL_OK;
    }

    if (idx == PRUNE) {
        if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "cutoff_ms"); return TCL_ERROR; }
        Tcl_WideInt cutoff;
        if (Tcl_GetWideIntFromObj(interp, objv[2], &cutoff) != TCL_OK) return TCL_ERROR;
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(ctx->db, "DELETE FROM run WHERE started < ?1;", -1, &st, NULL) != SQLITE_OK) {
            return fail_sqlite(interp, ctx);
        }
        sqlite3_bind_int64(st, 1, (sqlite3_int64)cutoff);
        if (sqlite3_step(st) != SQLITE_DONE) {
            int rc = fail_sqlite(interp, ctx);
            sqlite3_finalize(st);
            return rc;
        }
        sqlite3_finalize(st);
        Tcl_SetObjResult(interp, Tcl_NewIntObj(sqlite3_changes(ctx->db)));
        return TCL_OK;
    }

    /* STATS */
    if (objc != 2) { Tcl_WrongNumArgs(interp, 2, objv, ""); return TCL_ERROR; }
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(ctx->db,
            "SELECT COALESCE(status,'running') AS s, COUNT(*) FROM run GROUP BY s ORDER BY s;",
            -1, &st, NULL) != SQLITE_OK) {
        return fail_sqlite(interp, ctx);
    }
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_WideInt total = 0;
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        const char *s = (const char *)sqlite3_column_text(st, 0);
        Tcl_WideInt n = (Tcl_WideInt)sqlite3_column_int64(st, 1);
        total += n;
        Tcl_DictObjPut(interp, d, Tcl_NewStringObj(s ? s : "", -1), Tcl_NewWideIntObj(n));
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return fail_sqlite(interp, ctx);
    Tcl_DictObjPut(interp, d, Tcl_NewStringObj("rows", -1), Tcl_NewWideIntObj(total));
    Tcl_SetObjResult(interp, d);
    return TCL_OK;
}

static void JournalDelete(void *cd) {
    JournalCtx *ctx = (JournalCtx *)cd;
    if (ctx == NULL) return;
    if (ctx->db != NULL) sqlite3_close(ctx->db);
    Tcl_Free((char *)ctx);
}

int Machteldjournal_Init(Tcl_Interp *interp) {
    JournalCtx *ctx = (JournalCtx *)Tcl_Alloc(sizeof(JournalCtx));
    ctx->db = NULL;
    Tcl_CreateObjCommand(interp, "::machteld::journal", JournalCmd, ctx, JournalDelete);
    (void)COLS; /* the column list documents the schema for the reader */
    return TCL_OK;
}
