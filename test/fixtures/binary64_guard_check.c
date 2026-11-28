/* Private decimal guard on the same statically linked JSON reader as the host. */
#undef USE_TCL_STUBS
#include "tcl.h"
#include <fenv.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <xmmintrin.h>

static int call_guard(Tcl_Interp *ip, const char *command, Tcl_Obj *value, int code,
        const char *message, uint64_t expected) {
    Tcl_Obj *args[] = {Tcl_NewStringObj(command, -1), value};
    Tcl_IncrRefCount(args[0]);
    Tcl_IncrRefCount(value);
    const Tcl_ObjType *type = value->typePtr;
    int had_string = Tcl_HasStringRep(value);
    Tcl_Size references = value->refCount;
    int status = Tcl_EvalObjv(ip, 2, args, TCL_EVAL_GLOBAL);
    int ok = status == code;
    if (message != NULL) {
        ok = ok && strcmp(Tcl_GetStringResult(ip), message) == 0;
    } else {
        double number;
        uint64_t bits = 0;
        ok = ok && Tcl_GetDoubleFromObj(ip, Tcl_GetObjResult(ip), &number) == TCL_OK;
        if (ok) memcpy(&bits, &number, sizeof(bits));
        ok = ok && bits == expected;
    }
    Tcl_ResetResult(ip);
    ok = ok && value->typePtr == type && Tcl_HasStringRep(value) == had_string && value->refCount == references;
    if (!ok) {
        fprintf(stderr, "%s status %d/%d, original type retained %d, string %d/%d, references retained %d\n",
                command, status, code, value->typePtr == type, Tcl_HasStringRep(value), had_string,
                value->refCount == references);
    }
    Tcl_DecrRefCount(value);
    Tcl_DecrRefCount(args[0]);
    return ok;
}

static int call(Tcl_Interp *ip, Tcl_Obj *value, int code, const char *message, uint64_t expected) {
    return call_guard(ip, "::machteld::x::boundedBinary64", value, code, message, expected);
}

static int check_word(Tcl_Interp *ip, uint64_t bits, int finite, uint64_t expected) {
    double number;
    memcpy(&number, &bits, sizeof(number));
    return call_guard(ip, "::machteld::x::readBinary64", Tcl_NewDoubleObj(number),
            TCL_OK, finite ? NULL : "nonfinite", expected);
}

int CheckBinary64Guard(Tcl_Interp *ip) {
    int ok = call(ip, Tcl_NewWideIntObj(9007199254740993LL), TCL_OK, NULL, UINT64_C(0x4340000000000000));
    ok = call(ip, Tcl_NewStringObj("-000e-999", -1), TCL_OK, NULL, 0) && ok;
    ok = call(ip, Tcl_NewStringObj("5e-324", -1), TCL_OK, NULL, 1) && ok;
    ok = call(ip, Tcl_NewStringObj("2.2250738585072014e-308", -1), TCL_OK, NULL, UINT64_C(0x0010000000000000)) && ok;
    ok = call(ip, Tcl_NewStringObj("+00017", -1), TCL_OK, NULL, UINT64_C(0x4031000000000000)) && ok;
    ok = call(ip, Tcl_NewStringObj("1\0x", 3), TCL_ERROR, "expected a finite binary64 number", 0) && ok;
    ok = call(ip, Tcl_NewStringObj("0x10", -1), TCL_ERROR, "expected a finite binary64 number", 0) && ok;
    ok = call(ip, Tcl_NewStringObj("1e999", -1), TCL_ERROR, "binary64 overflow", 0) && ok;
    char wide[129];
    memset(wide, '0', sizeof(wide));
    wide[127] = '1';
    ok = call(ip, Tcl_NewStringObj(wide, 128), TCL_OK, NULL, UINT64_C(0x3ff0000000000000)) && ok;
    ok = call(ip, Tcl_NewStringObj(wide, 129), TCL_OK, "long", 0) && ok;

    fenv_t saved;
    if (fegetenv(&saved) != 0) return TCL_ERROR;
    unsigned csr = _mm_getcsr();
    const int modes[] = {FE_UPWARD, FE_DOWNWARD, FE_TOWARDZERO};
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); ++i) {
        ok = fesetround(modes[i]) == 0 && ok;
        ok = call(ip, Tcl_NewStringObj("0.1", -1), TCL_OK, "", 0) && ok;
        ok = fegetround() == modes[i] && ok;
    }
    fesetenv(&saved);
    _mm_setcsr(csr | 0x8040u);
    ok = call(ip, Tcl_NewStringObj("-5e-324", -1), TCL_OK, "", 0) && ok;
    ok = check_word(ip, UINT64_C(0x8000000000000001), 1, UINT64_C(0x8000000000000001)) && ok;
    ok = check_word(ip, UINT64_C(0x8000000000000000), 1, 0) && ok;
    ok = check_word(ip, UINT64_C(0x3e60000000000000), 1, UINT64_C(0x3e60000000000000)) && ok;
    ok = check_word(ip, UINT64_C(0x7ff0000000000000), 0, 0) && ok;
    ok = check_word(ip, UINT64_C(0xfff8000000000001), 0, 0) && ok;
    ok = call_guard(ip, "::machteld::x::readBinary64", Tcl_NewStringObj("5e-324", -1), TCL_OK, "", 0) && ok;
    _mm_setcsr(csr);
    if (!ok) {
        Tcl_SetObjResult(ip, Tcl_NewStringObj("binary64 guard mismatch", -1));
        return TCL_ERROR;
    }
    puts("binary64 guard retained inputs, exact bits, whole tokens and thread controls");
    return TCL_OK;
}
