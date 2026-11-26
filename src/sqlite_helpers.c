/* Extensions called from the pinned SQLite Tcl binding. */
#include "tcl.h"
#include "sqlite3.h"
#include <math.h>
#include <limits.h>
#include <string.h>

static int
parameter_error(Tcl_Interp *interp, int slot, const char *detail)
{
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("SQLite parameter ?%d: %s", slot, detail));
    Tcl_SetErrorCode(interp, "MACHTELD", "SQLITE", "parameter", NULL);
    return TCL_ERROR;
}

int
MachteldSqlBind(Tcl_Interp *interp, sqlite3_stmt *statement, int slot,
                Tcl_Obj *parameters, int required)
{
    static const char *const types[] = {"null", "integer", "real", "text", "blob", NULL};
    enum { SQL_NULL, SQL_INTEGER, SQL_REAL, SQL_TEXT, SQL_BLOB };
    Tcl_Obj *key = Tcl_NewIntObj(slot);
    Tcl_IncrRefCount(key);
    Tcl_Obj *entry = NULL;
    int status = Tcl_DictObjGet(interp, parameters, key, &entry);
    Tcl_DecrRefCount(key);
    if (status != TCL_OK) return TCL_ERROR;
    if (entry == NULL) {
        if (required) return parameter_error(interp, slot, "missing binding");
        /* SQLite reports the same NULL name for a bare ? and an unused gap.
         * Clear any value left by an earlier use of this cached statement. */
        int rc = sqlite3_bind_null(statement, slot);
        if (rc != SQLITE_OK) return parameter_error(interp, slot, sqlite3_errstr(rc));
        return TCL_OK;
    }
    Tcl_Size length;
    Tcl_Obj **parts;
    int type;
    if (Tcl_ListObjGetElements(interp, entry, &length, &parts) != TCL_OK ||
        length < 1 || Tcl_GetIndexFromObj(interp, parts[0], types, "type", TCL_EXACT, &type) != TCL_OK ||
        length != (type == SQL_NULL ? 1 : 2)) {
        return parameter_error(interp, slot, "expected {null} or {integer|real|text|blob value}");
    }
    int rc;
    switch (type) {
    case SQL_INTEGER: {
        void *number;
        int kind;
        if (Tcl_GetNumberFromObj(interp, parts[1], &number, &kind) != TCL_OK || kind != TCL_NUMBER_INT)
            return parameter_error(interp, slot, "expected a signed 64-bit integer");
        rc = sqlite3_bind_int64(statement, slot, *(Tcl_WideInt *)number);
        break;
    }
    case SQL_REAL: {
        double number;
        if (Tcl_GetDoubleFromObj(interp, parts[1], &number) != TCL_OK || isnan(number))
            return parameter_error(interp, slot, "expected a number representable as SQLite REAL");
        rc = sqlite3_bind_double(statement, slot, number);
        break;
    }
    case SQL_TEXT: {
        const char *input = Tcl_GetStringFromObj(parts[1], &length);
        Tcl_Encoding utf8 = Tcl_GetEncoding(NULL, "utf-8");
        Tcl_DString bytes;
        status = Tcl_UtfToExternalDStringEx(interp, utf8, input, length, TCL_ENCODING_PROFILE_STRICT, &bytes, NULL);
        Tcl_FreeEncoding(utf8);
        if (status != TCL_OK) {
            Tcl_DStringFree(&bytes);
            return parameter_error(interp, slot, "text must be valid Unicode");
        }
        rc = sqlite3_bind_text64(statement, slot, Tcl_DStringValue(&bytes),
                (sqlite3_uint64)Tcl_DStringLength(&bytes), SQLITE_TRANSIENT, SQLITE_UTF8);
        Tcl_DStringFree(&bytes);
        break;
    }
    case SQL_BLOB: {
        const unsigned char *bytes = Tcl_GetBytesFromObj(interp, parts[1], &length);
        if (bytes == NULL) return parameter_error(interp, slot, "expected bytes");
        rc = sqlite3_bind_blob64(statement, slot, bytes, (sqlite3_uint64)length, SQLITE_TRANSIENT);
        break;
    }
    default:
        rc = sqlite3_bind_null(statement, slot);
    }
    if (rc != SQLITE_OK) return parameter_error(interp, slot, sqlite3_errstr(rc));
    return TCL_OK;
}

Tcl_Obj *
MachteldSqlColumnText(sqlite3_stmt *statement, int column)
{
    const unsigned char *text = sqlite3_column_text(statement, column);
    if (text == NULL) return Tcl_NewObj();
    int length = sqlite3_column_bytes(statement, column);
    Tcl_Encoding utf8 = Tcl_GetEncoding(NULL, "utf-8");
    Tcl_DString value;
    Tcl_ExternalToUtfDString(utf8, (const char *)text, length, &value);
    Tcl_FreeEncoding(utf8);
    return Tcl_DStringToObj(&value);
}

/* Decode a SQLite UTF-8 value without silently replacing invalid bytes. */
static Tcl_Obj *
decode_utf8(Tcl_Interp *interp, Tcl_Encoding encoding, const char *bytes, Tcl_Size length)
{
    Tcl_DString result;
    if (Tcl_ExternalToUtfDStringEx(interp, encoding, bytes, length,
            TCL_ENCODING_PROFILE_STRICT, &result, NULL) != TCL_OK) {
        Tcl_DStringFree(&result);
        Tcl_SetErrorCode(interp, "MACHTELD", "SQLITE", "text", NULL);
        return NULL;
    }
    return Tcl_DStringToObj(&result);
}

static int
sql_error(Tcl_Interp *interp, const char *operation, const char *message)
{
    Tcl_SetObjResult(interp, Tcl_NewStringObj(message, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "SQLITE", operation, NULL);
    return TCL_ERROR;
}

int
MachteldSqlInspect(Tcl_Interp *interp, sqlite3 *db, Tcl_Obj *sql)
{
    Tcl_Size length;
    const char *input = Tcl_GetStringFromObj(sql, &length);
    Tcl_Encoding utf8 = Tcl_GetEncoding(NULL, "utf-8");
    Tcl_DString encoded;
    sqlite3_stmt *statement = NULL;
    Tcl_Obj *result = Tcl_NewDictObj();
    Tcl_IncrRefCount(result);
    int status = TCL_ERROR;
    if (Tcl_UtfToExternalDStringEx(interp, utf8, input, length,
            TCL_ENCODING_PROFILE_STRICT, &encoded, NULL) != TCL_OK) {
        sql_error(interp, "inspect", "SQL must be valid Unicode");
        goto done;
    }
    const char *bytes = Tcl_DStringValue(&encoded);
    length = Tcl_DStringLength(&encoded);
    if (length > INT_MAX || memchr(bytes, 0, (size_t)length) != NULL) {
        sql_error(interp, "inspect", "SQL exceeds the prepare limit or contains NUL");
        goto done;
    }
    const char *tail = NULL;
    if (sqlite3_prepare_v3(db, bytes, (int)length, 0, &statement, &tail) != SQLITE_OK) {
        sql_error(interp, "inspect", sqlite3_errmsg(db));
        goto done;
    }
    Tcl_Obj *suffix = decode_utf8(interp, utf8, tail, length - (tail - bytes));
    if (suffix == NULL) goto done;
    Tcl_Obj *columns = Tcl_NewListObj(0, NULL);
    Tcl_Obj *parameters = Tcl_NewListObj(0, NULL);
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("tail", -1), suffix);
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("columns", -1), columns);
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("parameters", -1), parameters);
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("statement", -1), Tcl_NewBooleanObj(statement != NULL));
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("readonly", -1),
            Tcl_NewBooleanObj(statement && sqlite3_stmt_readonly(statement)));
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("explain", -1),
            Tcl_NewIntObj(statement ? sqlite3_stmt_isexplain(statement) : 0));
    if (statement) {
        for (int i = 0; i < sqlite3_column_count(statement); i++) {
            const char *name = sqlite3_column_name(statement, i);
            if (name == NULL) {
                sql_error(interp, "inspect", sqlite3_errstr(SQLITE_NOMEM));
                goto done;
            }
            Tcl_Obj *column = decode_utf8(interp, utf8, name, -1);
            if (column == NULL) goto done;
            Tcl_ListObjAppendElement(NULL, columns, column);
        }
        int count = sqlite3_bind_parameter_count(statement);
        for (int slot = 1; slot <= count; slot++) {
            const char *name = sqlite3_bind_parameter_name(statement, slot);
            Tcl_Obj *parameter = name ? decode_utf8(interp, utf8, name, -1) : Tcl_NewObj();
            if (parameter == NULL) goto done;
            Tcl_ListObjAppendElement(NULL, parameters, parameter);
        }
    }
    Tcl_SetObjResult(interp, result);
    status = TCL_OK;
done:
    sqlite3_finalize(statement);
    Tcl_DStringFree(&encoded);
    Tcl_FreeEncoding(utf8);
    Tcl_DecrRefCount(result);
    return status;
}

/* The eval context owns one reference until it advances or finalizes. */
int
MachteldSqlTypedRow(Tcl_Interp *interp, sqlite3_stmt *statement, Tcl_Obj **out)
{
    Tcl_Obj *row = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(row);
    Tcl_Encoding utf8 = NULL;
    for (int i = 0; i < sqlite3_column_count(statement); i++) {
        const char *tag;
        Tcl_Obj *value = NULL;
        switch (sqlite3_column_type(statement, i)) {
        case SQLITE_INTEGER:
            tag = "integer";
            value = Tcl_NewWideIntObj(sqlite3_column_int64(statement, i));
            break;
        case SQLITE_FLOAT:
            tag = "real";
            value = Tcl_NewDoubleObj(sqlite3_column_double(statement, i));
            break;
        case SQLITE_TEXT: {
            tag = "text";
            const unsigned char *bytes = sqlite3_column_text(statement, i);
            if (bytes == NULL) {
                sql_error(interp, "text", sqlite3_errstr(SQLITE_NOMEM));
                goto fail;
            }
            if (utf8 == NULL) utf8 = Tcl_GetEncoding(NULL, "utf-8");
            value = decode_utf8(interp, utf8, (const char *)bytes, sqlite3_column_bytes(statement, i));
            if (value == NULL) goto fail;
            break;
        }
        case SQLITE_BLOB: {
            tag = "blob";
            const void *bytes = sqlite3_column_blob(statement, i);
            if (bytes == NULL && sqlite3_errcode(sqlite3_db_handle(statement)) == SQLITE_NOMEM) {
                sql_error(interp, "blob", sqlite3_errstr(SQLITE_NOMEM));
                goto fail;
            }
            value = Tcl_NewByteArrayObj(bytes, sqlite3_column_bytes(statement, i));
            break;
        }
        default:
            tag = "null";
        }
        Tcl_Obj *parts[] = {Tcl_NewStringObj(tag, -1), value};
        Tcl_ListObjAppendElement(NULL, row, Tcl_NewListObj(value ? 2 : 1, parts));
    }
    if (utf8) Tcl_FreeEncoding(utf8);
    *out = row;
    return TCL_OK;
fail:
    if (utf8) Tcl_FreeEncoding(utf8);
    Tcl_DecrRefCount(row);
    return TCL_ERROR;
}
