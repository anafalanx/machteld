/* The Tcl binding calls these only for db eval -parameters. SQLite's own
 * preparer supplies the slot number, including repeated and sparse ?NNN. */
#include "tcl.h"
#include "sqlite3.h"
#include <math.h>

static int
parameter_error(Tcl_Interp *interp, int slot, const char *detail)
{
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("SQLite parameter ?%d: %s", slot, detail));
    Tcl_SetErrorCode(interp, "MACHTELD", "SQLITE", "parameter", NULL);
    return TCL_ERROR;
}

int
MachteldSqlBind(Tcl_Interp *interp, sqlite3_stmt *statement, int slot,
                Tcl_Obj *parameters)
{
    static const char *const types[] = {"null", "integer", "real", "text", "blob", NULL};
    enum { SQL_NULL, SQL_INTEGER, SQL_REAL, SQL_TEXT, SQL_BLOB };
    Tcl_Obj *key = Tcl_NewIntObj(slot);
    Tcl_IncrRefCount(key);
    Tcl_Obj *entry = NULL;
    int status = Tcl_DictObjGet(interp, parameters, key, &entry);
    Tcl_DecrRefCount(key);
    if (status != TCL_OK) return TCL_ERROR;
    if (entry == NULL) return parameter_error(interp, slot, "missing binding");
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
