/* Charset detection adapted from Els src/icudet.c at
 * f8d0c118e1f7e8cd9f66a2eee76be5a3106fe969. Copyright (c) 2026
 * Vincent Vercauteren, MIT; see licenses/Els-MIT.txt. Windows owns ICU. */
#undef USE_TCL_STUBS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include "machteld.h"

typedef struct UCharsetDetector Detector;
typedef struct UCharsetMatch Match;
typedef int32_t IcuError;
static struct {
    union { FARPROC address; Detector *(*call)(IcuError *); } open;
    union { FARPROC address; void (*call)(Detector *, const char *, int32_t, IcuError *); } set_text;
    union { FARPROC address; const Match *(*call)(Detector *, IcuError *); } detect;
    union { FARPROC address; const char *(*call)(const Match *, IcuError *); } name;
    union { FARPROC address; int32_t (*call)(const Match *, IcuError *); } confidence;
    union { FARPROC address; void (*call)(Detector *); } close;
    HMODULE module;
} icu;
static INIT_ONCE icu_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK initialize_icu(PINIT_ONCE once, void *param, void **context) {
    (void)once; (void)param; (void)context;
    HMODULE module = LoadLibraryExW(L"icu.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return TRUE;
    icu.open.address = GetProcAddress(module, "ucsdet_open");
    icu.set_text.address = GetProcAddress(module, "ucsdet_setText");
    icu.detect.address = GetProcAddress(module, "ucsdet_detect");
    icu.name.address = GetProcAddress(module, "ucsdet_getName");
    icu.confidence.address = GetProcAddress(module, "ucsdet_getConfidence");
    icu.close.address = GetProcAddress(module, "ucsdet_close");
    if (icu.open.address && icu.set_text.address && icu.detect.address &&
            icu.name.address && icu.confidence.address && icu.close.address) {
        icu.module = module; /* Process-lifetime imports; each call owns its detector. */
    } else FreeLibrary(module);
    return TRUE;
}

static int detection(Tcl_Interp *interp, const char *status, const char *name, int confidence, Tcl_Size n) {
    Tcl_Obj *result = Tcl_NewDictObj();
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("status", -1), Tcl_NewStringObj(status, -1));
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("encoding", -1), Tcl_NewStringObj(name, -1));
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("confidence", -1), Tcl_NewIntObj(confidence));
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("samplebytes", -1), Tcl_NewWideIntObj(n));
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
}

static int printable_ascii(const unsigned char *p, Tcl_Size n) {
    for (Tcl_Size i = 0; i < n; ++i) {
        unsigned char c = p[i];
        if (c >= 0x20 && c <= 0x7e) continue;
        if (c != '\t' && c != '\n' && c != '\r' && c != '\f') return 0;
    }
    return 1;
}

static int detect_cmd(void *client, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)client;
    if (objc != 2) {Tcl_WrongNumArgs(interp, 1, objv, "bytes"); return TCL_ERROR;}
    Tcl_Obj *input = objv[1];
    /* Both Tcl 9 bytearray implementations have this type NAME. A coercion
     * from arbitrary Unicode would invent input bytes before detection. */
    if (!input->typePtr || !input->typePtr->name || strcmp(input->typePtr->name, "bytearray")) {
        if (Tcl_GetCharLength(input) == 0) return detection(interp, "nomatch", "", 0, 0);
        Tcl_SetObjResult(interp, Tcl_NewStringObj("encoding detection requires a bytearray; open the file in binary mode", -1));
        Tcl_SetErrorCode(interp, "MACHTELD", "ENCODING", "badvalue", NULL);
        return TCL_ERROR;
    }
    Tcl_Size n = 0;
    const unsigned char *bytes = Tcl_GetBytesFromObj(interp, input, &n);
    if (!bytes && n != 0) return TCL_ERROR;
    /* Els samples at most 1 MiB; the length passed to ICU always fits int32. */
    if (n > 1048576) n = 1048576;
    if (printable_ascii(bytes, n)) return detection(interp, "nomatch", "", 0, n);
    if (!InitOnceExecuteOnce(&icu_once, initialize_icu, NULL, NULL) || !icu.module) {
        return detection(interp, "unavailable", "", 0, n);
    }
    IcuError error = 0;
    Detector *detector = icu.open.call(&error);
    if (error > 0 || !detector) {
        if (detector) icu.close.call(detector);
        Tcl_SetObjResult(interp, Tcl_NewStringObj("cannot create the ICU character set detector", -1));
        Tcl_SetErrorCode(interp, "MACHTELD", "ENCODING", "oserror", NULL);
        return TCL_ERROR;
    }
    icu.set_text.call(detector, (const char *)bytes, (int32_t)n, &error);
    const Match *match = error <= 0 ? icu.detect.call(detector, &error) : NULL;
    const char *name = NULL;
    int confidence = 0;
    if (match && error <= 0) {
        name = icu.name.call(match, &error);
        if (error <= 0 && name) confidence = icu.confidence.call(match, &error);
    }
    int rc;
    if (name && name[0] && error <= 0 && confidence > 0 && confidence <= 100) {
        rc = detection(interp, "match", name, confidence, n);
    } else {
        rc = detection(interp, "nomatch", "", 0, n);
    }
    icu.close.call(detector);
    return rc;
}

int Machteldencoding_Init(Tcl_Interp *interp) {
    if (Tcl_EvalEx(interp, "namespace eval ::machteld::encoding {}", -1, TCL_EVAL_GLOBAL) != TCL_OK) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "::machteld::encoding::detect", detect_cmd, NULL, NULL);
    return Tcl_PkgProvide(interp, "machteld::encoding", "1.0");
}
