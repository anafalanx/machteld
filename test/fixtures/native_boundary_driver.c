/* Deterministic fault injection at native filesystem and SQLite boundaries.
 * Includes the authored implementations; no production test switches. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <wchar.h>
#include "../../src/machteld.h"
#include "sqlite3.h"

static DWORD fake_final_path(HANDLE handle, LPWSTR buffer, DWORD capacity, DWORD flags) {
    (void)handle; (void)flags;
    if (buffer == NULL) return 16;
    /* Synthetic inconsistent boundary: a successful length must be below
     * capacity. This negative control is not a live Win32 path-growth repro;
     * documented insufficient-buffer returns are larger than capacity. */
    wmemset(buffer, L'x', capacity);
    return capacity;
}
#define GetFinalPathNameByHandleW fake_final_path
#ifndef BOUNDARY_DIRS_SOURCE
#define BOUNDARY_DIRS_SOURCE "../../src/dirs.c"
#endif
#include BOUNDARY_DIRS_SOURCE
#undef GetFinalPathNameByHandleW

static int inject_step, inject_finalize, tracking, freed;
static const Tcl_ObjType *original_type;
static Tcl_ObjType tracked_type;
static void tracked_free(Tcl_Obj *value) {
    ++freed;
    value->typePtr = original_type;
    if (original_type && original_type->freeIntRepProc) original_type->freeIntRepProc(value);
}
static Tcl_Obj *track(Tcl_Obj *value) {
    if (tracking) {
        original_type = value->typePtr;
        memset(&tracked_type, 0, sizeof tracked_type);
        if (original_type) tracked_type = *original_type;
        tracked_type.name = "boundary-test-owned-result";
        tracked_type.freeIntRepProc = tracked_free;
        value->typePtr = &tracked_type;
    }
    return value;
}
static Tcl_Obj *tracked_list(Tcl_Size count, Tcl_Obj *const values[]) {
    return track(Tcl_NewListObj(count, values));
}
static Tcl_Obj *tracked_bytes(const unsigned char *bytes, Tcl_Size count) {
    return track(Tcl_NewByteArrayObj(bytes, count));
}
static int fault_step(sqlite3_stmt *statement) {
    return inject_step ? SQLITE_IOERR : sqlite3_step(statement);
}
static int fault_finalize(sqlite3_stmt *statement) {
    int result = sqlite3_finalize(statement);
    return inject_finalize ? SQLITE_IOERR : result;
}
#define Tcl_NewListObj tracked_list
#define Tcl_NewByteArrayObj tracked_bytes
#define sqlite3_step fault_step
#define sqlite3_finalize fault_finalize
#ifndef BOUNDARY_STORE_SOURCE
#define BOUNDARY_STORE_SOURCE "../../src/store.c"
#endif
#include BOUNDARY_STORE_SOURCE
#undef Tcl_NewListObj
#undef Tcl_NewByteArrayObj
#undef sqlite3_step
#undef sqlite3_finalize

static Tcl_Obj *tracked_header_string(const char *bytes, Tcl_Size count) {
    Tcl_Obj *value = Tcl_NewStringObj(bytes, count);
    return count == 11 && memcmp(bytes, "x-duplicate", 11) == 0 ? track(value) : value;
}
#define Tcl_NewStringObj tracked_header_string
#ifndef BOUNDARY_HTTP_SOURCE
#define BOUNDARY_HTTP_SOURCE "../../src/http.c"
#endif
#include BOUNDARY_HTTP_SOURCE
#undef Tcl_NewStringObj

static int failures, checks;
static void check(const char *name, int condition) {
    ++checks;
    printf("%s %s\n", condition ? "ok  " : "FAIL", name);
    if (!condition) ++failures;
}
int main(int argc, char **argv) {
    (void)argc;
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    Tcl_FindExecutable(argv[0]);
    Tcl_Interp *interp = Tcl_CreateInterp();
    check("dirs init", Machtelddirs_Init(interp) == TCL_OK);
    check("canonical path refuses synthetic equal-capacity result", Tcl_Eval(interp,
        "::machteld::canon .") == TCL_ERROR);
    const char *error_code = Tcl_GetVar(interp, "errorCode", TCL_GLOBAL_ONLY);
    check("invalid capacity result has stable error code", error_code != NULL &&
        strcmp(error_code, "MACHTELD DIRS oserror") == 0);
#ifndef BOUNDARY_BEFORE_CAPACITY_GUARDS
    check("capacity starts bounded", dirs_capacity(0, 0, 1, 16) == 32);
    check("capacity grows", dirs_capacity(32, 30, 5, 16) == 64);
    check("capacity refuses addition overflow", dirs_capacity(32, SIZE_MAX, 1, 16) == 0);
    check("capacity refuses multiplication overflow", dirs_capacity(32, 0, SIZE_MAX, 16) == 0);
    check("join refuses synthetic overflow", dirs_join(L"", SIZE_MAX, L"", 1) == NULL);
    check("join refuses suffix overflow", dirs_join(L"", 0, L"", SIZE_MAX) == NULL);
#endif
    check("store init", Machteldstore_Init(interp) == TCL_OK);
    check("store fixture", Tcl_Eval(interp,
        "::machteld::store open; ::machteld::store put key value") == TCL_OK);
    tracking = 1; inject_finalize = 1; freed = 0;
    check("GET finalization error", Tcl_Eval(interp, "::machteld::store get key") == TCL_ERROR);
    check("GET error releases result", freed == 1);
    int missing_result = Tcl_Eval(interp, "::machteld::store get missing");
    error_code = Tcl_GetVar(interp, "errorCode", TCL_GLOBAL_ONLY);
    check("missing GET finalization error not hidden as notfound",
        missing_result == TCL_ERROR && error_code != NULL &&
        strcmp(error_code, "MACHTELD STORE sqlite") == 0);
    inject_finalize = 0; inject_step = 1; freed = 0;
    check("KEYS stepping error", Tcl_Eval(interp, "::machteld::store keys") == TCL_ERROR);
    check("KEYS error releases result", freed == 1);
    tracking = 0; inject_step = 0;
    check("store usable after errors", Tcl_Eval(interp,
        "::machteld::store get key; ::machteld::store close") == TCL_OK);
    Tcl_Obj *headers = Tcl_NewDictObj();
    Tcl_IncrRefCount(headers);
    tracking = 1; freed = 0;
    check("first HTTP header", http_put_header(headers, "X-Duplicate: first", 18));
    check("duplicate HTTP header", http_put_header(headers, "X-Duplicate: next", 17));
    check("duplicate header key is released", freed == 1);
    tracking = 0;
    Tcl_DecrRefCount(headers);
    check("retained header key released with dictionary", freed == 2);
    Tcl_DeleteInterp(interp);
    Tcl_Finalize();
    printf("native boundary: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
