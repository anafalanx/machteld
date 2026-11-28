/* Exercise borrowed Tcl_Obj representations in the real statically linked guard. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <tcl.h>
#if defined(_WIN64) && (defined(_M_X64) || defined(__x86_64__))
#include <xmmintrin.h>
#endif

extern int MachteldCompilerGuard_Init(Tcl_Interp *interp);

static int
call_command(Tcl_Interp *interp, const char *command, Tcl_Obj *input, int expected_code, const char *expected)
{
    Tcl_Obj *args[] = {
        Tcl_NewStringObj(command, -1),
        input, Tcl_NewStringObj("amounts", -1)
    };
    for (size_t i = 0; i < 3; ++i) {
        Tcl_IncrRefCount(args[i]);
    }
    int code = Tcl_EvalObjv(interp, 3, args, TCL_EVAL_GLOBAL);
    int ok = code == expected_code && strcmp(Tcl_GetStringResult(interp), expected) == 0;
    if (!ok) {
        fprintf(stderr, "expected %d %s, got %d %s\n", expected_code, expected, code, Tcl_GetStringResult(interp));
    }
    for (size_t i = 0; i < 3; ++i) {
        Tcl_DecrRefCount(args[i]);
    }
    Tcl_ResetResult(interp);
    return ok;
}

static int
call(Tcl_Interp *interp, Tcl_Obj *input, int expected_code, const char *expected)
{
    return call_command(interp, "::machteld::GuardIntegerList", input, expected_code, expected);
}

static int
retained(Tcl_Interp *interp, Tcl_Obj *word, const Tcl_ObjType *type, const char *expected)
{
    Tcl_IncrRefCount(word);
    Tcl_Obj *members[] = {word, Tcl_NewStringObj("bad", -1)};
    Tcl_Obj *complete = Tcl_NewListObj(1, members);
    Tcl_Obj *partial = Tcl_NewListObj(2, members);
    Tcl_IncrRefCount(complete);
    Tcl_IncrRefCount(partial);
    int references = word->refCount;
    int ok = Tcl_FetchInternalRep(word, type) != NULL;
    for (int i = 0; ok && i < 16; ++i) {
        ok = call(interp, complete, TCL_OK, expected) &&
            call(interp, partial, TCL_ERROR, "expected int at amounts.1") &&
            call(interp, word, TCL_OK, expected) &&
            call_command(interp, "::machteld::x::guardInteger", word, TCL_OK, expected) &&
            Tcl_FetchInternalRep(word, type) != NULL && word->refCount == references;
    }
    Tcl_DecrRefCount(partial);
    Tcl_DecrRefCount(complete);
    Tcl_DecrRefCount(word);
    return ok;
}

static int
check_key(Tcl_Interp *interp, Tcl_Obj *input, int expected_code,
          const char *expected, Tcl_Size expected_size, int has_nul)
{
    Tcl_Obj *command = Tcl_NewStringObj("::machteld::x::mapTextKey", -1);
    Tcl_Obj *args[] = {command, input};
    Tcl_IncrRefCount(command);
    Tcl_IncrRefCount(input);
    const Tcl_ObjType *original_type = input->typePtr;
    int code = Tcl_EvalObjv(interp, 2, args, TCL_EVAL_GLOBAL);
    Tcl_Size size;
    const char *result = Tcl_GetStringFromObj(Tcl_GetObjResult(interp), &size);
    int ok = code == expected_code && input->typePtr == original_type &&
        (expected == NULL || (size == expected_size &&
            memcmp(result, expected, (size_t)expected_size) == 0));
    if (!ok) {
        fprintf(stderr, "map key returned code %d, length %lld, or changed input type\n",
            code, (long long)size);
    }
    Tcl_ResetResult(interp);
    Tcl_DecrRefCount(command);
    args[0] = Tcl_NewStringObj("::machteld::x::textHasNul", -1);
    Tcl_IncrRefCount(args[0]);
    int found;
    if (Tcl_EvalObjv(interp, 2, args, TCL_EVAL_GLOBAL) != TCL_OK ||
        Tcl_GetBooleanFromObj(interp, Tcl_GetObjResult(interp), &found) != TCL_OK ||
        found != has_nul || input->typePtr != original_type) {
        fputs("text NUL probe returned a wrong answer or changed the input type\n", stderr);
        ok = 0;
    }
    Tcl_ResetResult(interp);
    Tcl_DecrRefCount(args[0]);
    Tcl_DecrRefCount(input);
    return ok;
}

static int
check_text_length(Tcl_Interp *interp, Tcl_Obj *value, Tcl_WideInt expected)
{
    Tcl_Obj *args[] = {Tcl_NewStringObj("::machteld::x::textLength", -1), value};
    Tcl_IncrRefCount(args[0]);
    Tcl_IncrRefCount(value);
    const Tcl_ObjType *type = value->typePtr;
    int had_string = Tcl_HasStringRep(value);
    int ok = 1;
    for (int i = 0; i < 2 && ok; ++i) {
        Tcl_WideInt actual;
        ok = Tcl_EvalObjv(interp, 2, args, TCL_EVAL_GLOBAL) == TCL_OK &&
            Tcl_GetWideIntFromObj(interp, Tcl_GetObjResult(interp), &actual) == TCL_OK &&
            actual == expected;
        Tcl_ResetResult(interp);
        if (type != NULL) {
            ok = ok && value->typePtr == type && Tcl_HasStringRep(value) == had_string;
        }
    }
    if (!ok) {fprintf(stderr, "textLength failed for expected length %lld\n", (long long)expected);}
    Tcl_DecrRefCount(value);
    Tcl_DecrRefCount(args[0]);
    return ok;
}

/* A repeated row shares the same input object in two list slots. Its integer,
 * optional payload and unknown field also share an object with a deliberately
 * cached double representation. Check every original reference after clearing
 * both a successful result and an error from a later row. */
static int
record_retained(Tcl_Interp *interp, Tcl_Obj *word)
{
    Tcl_Obj *layout = Tcl_NewStringObj("n int opt int?", -1);
    Tcl_Obj *element = Tcl_NewStringObj("row", -1);
    Tcl_Obj *path = Tcl_NewStringObj("data", -1);
    Tcl_Obj *name = Tcl_NewStringObj("::machteld::GuardRecordList", -1);
    Tcl_Obj *parts[] = {Tcl_NewStringObj("some", -1), word};
    Tcl_Obj *opt = Tcl_NewListObj(2, parts);
    Tcl_Obj *row = Tcl_NewDictObj();
    Tcl_DictObjPut(NULL, row, Tcl_NewStringObj("n", -1), word);
    Tcl_DictObjPut(NULL, row, Tcl_NewStringObj("opt", -1), opt);
    Tcl_DictObjPut(NULL, row, Tcl_NewStringObj("extra", -1), word);
    Tcl_Obj *items[] = {row, row, Tcl_NewStringObj("n 17\0xx", 7)};
    Tcl_Obj *good = Tcl_NewListObj(2, items);
    Tcl_Obj *bad = Tcl_NewListObj(3, items);
    Tcl_Obj *owned[] = {name, layout, element, path, word, opt, row, good, bad};
    enum {length = sizeof owned / sizeof owned[0]};
    Tcl_Size refs[length];
    const Tcl_ObjType *types[length];
    for (size_t i = 0; i < length; ++i) {
        Tcl_IncrRefCount(owned[i]);
        refs[i] = owned[i]->refCount;
        types[i] = owned[i]->typePtr;
    }
    int ok = 1;
    for (int n = 0; n < 100 && ok; ++n) {
        Tcl_Obj *args[] = {name, layout, element, n % 2 ? bad : good, path};
        int status = Tcl_EvalObjv(interp, 5, args, TCL_EVAL_GLOBAL);
        const char *result = Tcl_GetStringResult(interp);
        if (n % 2) {
            ok = status == TCL_ERROR && strcmp(result, "expected int at data.2.n") == 0;
        } else {
            ok = status == TCL_OK && strcmp(result,
                "{n 17 opt {some 17} extra 17} {n 17 opt {some 17} extra 17}") == 0;
        }
        Tcl_ResetResult(interp);
        for (size_t i = 0; i < length; ++i) {
            /* Tcl's own command resolver can attach a command-name cache. */
            ok = ok && owned[i]->refCount == refs[i] && (i == 0 || owned[i]->typePtr == types[i]);
        }
    }
    for (size_t i = length; i > 0; --i) {Tcl_DecrRefCount(owned[i - 1]);}
    if (!ok) {fputs("record list boundary changed a borrowed object or reference count\n", stderr);}
    return ok;
}

/* A consumer may convert its returned integer to bytes. Neither that change
 * nor a later row failing admission may touch the borrowed numeric object. */
static int
fresh_integer(Tcl_Interp *interp, Tcl_Obj *input, const char *expected)
{
    const Tcl_ObjType *type = input->typePtr;
    Tcl_IncrRefCount(input);
    Tcl_SetVar2Ex(interp, "numericInput", NULL, input, TCL_GLOBAL_ONLY);
    Tcl_Size references = input->refCount;
    const char *scripts[] = {
        "::machteld::x::guardInteger $numericInput x",
        "lindex [::machteld::GuardIntegerList [list $numericInput] x] 0",
        "lindex [::machteld::GuardIntegerList [lrepeat 129 $numericInput] x] 64",
        "dict get [lindex [::machteld::GuardRecordList {n int} r [list [dict create n $numericInput]] x] 0] n",
        "lindex [dict get [lindex [::machteld::GuardRecordList {n int?} r [list [dict create n [list some $numericInput]]] x] 0] n] 1"
    };
    int ok = !Tcl_HasStringRep(input);
    for (size_t i = 0; ok && i < sizeof scripts / sizeof scripts[0]; ++i) {
        ok = Tcl_Eval(interp, scripts[i]) == TCL_OK;
        Tcl_Obj *out = Tcl_GetObjResult(interp);
        ok = ok && out != input && strcmp(Tcl_GetString(out), expected) == 0;
        Tcl_Size bytes;
        (void)Tcl_GetByteArrayFromObj(out, &bytes);
        Tcl_ResetResult(interp);
        ok = ok && input->typePtr == type && !Tcl_HasStringRep(input) && input->refCount == references;
    }
    const char *bad[][2] = {
        {"::machteld::GuardIntegerList [list $numericInput bad] x", "expected int at x.1"},
        {"::machteld::GuardIntegerList [lreplace [lrepeat 66 $numericInput] 65 65 bad] x", "expected int at x.65"}
    };
    for (size_t i = 0; ok && i < sizeof bad / sizeof bad[0]; ++i) {
        ok = Tcl_Eval(interp, bad[i][0]) == TCL_ERROR && strcmp(Tcl_GetStringResult(interp), bad[i][1]) == 0;
        Tcl_ResetResult(interp);
        ok = ok && input->typePtr == type && !Tcl_HasStringRep(input) && input->refCount == references;
    }
    Tcl_UnsetVar(interp, "numericInput", TCL_GLOBAL_ONLY);
    Tcl_DecrRefCount(input);
    return ok;
}

static int
check_binary64_print(Tcl_Interp *interp, Tcl_Obj *value, const char *expected)
{
    Tcl_Obj *args[] = {Tcl_NewStringObj("::machteld::x::binary64Print", -1), value};
    Tcl_IncrRefCount(args[0]);
    Tcl_IncrRefCount(value);
    const Tcl_ObjType *type = value->typePtr;
    int had_string = Tcl_HasStringRep(value);
    int references = value->refCount;
    int ok = Tcl_EvalObjv(interp, 2, args, TCL_EVAL_GLOBAL) == TCL_OK &&
        strcmp(Tcl_GetStringResult(interp), expected) == 0 && value->typePtr == type &&
        Tcl_HasStringRep(value) == had_string && value->refCount == references;
    if (!ok) {fprintf(stderr, "binary64 print expected '%s', got '%s' or changed input\n",
        expected, Tcl_GetStringResult(interp));}
    Tcl_ResetResult(interp);
    Tcl_DecrRefCount(value);
    Tcl_DecrRefCount(args[0]);
    return ok;
}

static int
check_decimal_operands(Tcl_Interp *interp)
{
    Tcl_Obj *args[] = {Tcl_NewStringObj("::machteld::x::tryDecimalArithmetic", -1),
            Tcl_NewStringObj("*", 1), Tcl_NewByteArrayObj((const unsigned char *)"0.04", 4),
            Tcl_NewStringObj("0.25", 4)};
    for (int i = 0; i < 4; ++i) Tcl_IncrRefCount(args[i]);
    const Tcl_ObjType *borrowed_type = args[2]->typePtr;
    int had_string = Tcl_HasStringRep(args[2]);
    int ok = Tcl_EvalObjv(interp, 4, args, TCL_EVAL_GLOBAL) == TCL_OK &&
            strcmp(Tcl_GetStringResult(interp), "") == 0 && args[2]->typePtr == borrowed_type &&
            Tcl_HasStringRep(args[2]) == had_string && args[2]->refCount == 1;
    Tcl_DecrRefCount(args[2]);
    args[2] = Tcl_NewStringObj("-0.04", 5);
    Tcl_IncrRefCount(args[2]);
    ok = Tcl_EvalObjv(interp, 4, args, TCL_EVAL_GLOBAL) == TCL_OK && ok;
    Tcl_Obj *answer = Tcl_GetObjResult(interp);
    ok = answer != args[2] && answer != args[3] && answer->typePtr == Tcl_GetObjType("string") &&
            strcmp(Tcl_GetString(answer), "-0.01") == 0 && args[2]->refCount == 1 && args[3]->refCount == 1 && ok;
    for (int i = 0; i < 4; ++i) Tcl_DecrRefCount(args[i]);
    Tcl_ResetResult(interp);
    return ok;
}

static int
check_binary64_print_words(Tcl_Interp *interp)
{
    if (!Tcl_FindCommand(interp, "::machteld::x::binary64Print", NULL, TCL_GLOBAL_ONLY)) {
        return 1; /* Optional on older UCRTs and other platforms. */
    }
    static const struct {uint64_t bits; const char *text;} cases[] = {
        {UINT64_C(0x8000000000000000), "-0"}, {1, "4.9406564584124654e-324"},
        {UINT64_C(0x3e60000000000000), "2.9802322387695312e-08"},
        {UINT64_C(0xbffb1c6800000000), "-1.6944351196289062"},
        {UINT64_C(0x7fefffffffffffff), "1.7976931348623157e+308"},
        {UINT64_C(0x7ff0000000000000), ""}
    };
    for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); ++i) {
        double number;
        memcpy(&number, &cases[i].bits, sizeof(number));
        if (!check_binary64_print(interp, Tcl_NewDoubleObj(number), cases[i].text)) {return 0;}
    }
#if defined(_WIN64) && (defined(_M_X64) || defined(__x86_64__))
    /* Ordinary conversion must preserve even pre-existing status flags.
     * Directed rounding, flush-to-zero and unmasked inexact must decline. */
    const unsigned controls[] = {0x1f80u, 0x1fa4u, 0x5f80u, 0x9fc0u, 0x0f80u};
    unsigned saved = _mm_getcsr();
    for (size_t i = 0; i < sizeof(controls)/sizeof(controls[0]); ++i) {
        _mm_setcsr(controls[i]);
        int ok = check_binary64_print(interp, Tcl_NewDoubleObj(0.1),
            i < 2 ? "0.10000000000000001" : "") && _mm_getcsr() == controls[i];
        _mm_setcsr(saved);
        if (!ok) {return 0;}
    }
#endif
    return check_binary64_print(interp, Tcl_NewStringObj("1.25", -1), "") &&
        check_binary64_print(interp, Tcl_NewByteArrayObj((const unsigned char *)"1.25", 4), "");
}

static int
check_binary64_operator_controls(Tcl_Interp *interp)
{
#if defined(_WIN64) && (defined(_M_X64) || defined(__x86_64__))
    const char *command = "::machteld::x::binary64v1::multiply";
    if (!Tcl_FindCommand(interp, command, NULL, TCL_GLOBAL_ONLY)) {return 1;}
    Tcl_Obj *args[] = {Tcl_NewStringObj(command, -1), Tcl_NewDoubleObj(0.1), Tcl_NewDoubleObj(0.1)};
    for (size_t i = 0; i < 3; ++i) {Tcl_IncrRefCount(args[i]);}
    /* Ordinary, pre-existing sticky flags, upward rounding, FTZ+DAZ and
     * unmasked inexact. Each must return exactly the nearest-even product. */
    static const unsigned controls[] = {0x1f80u, 0x1fa4u, 0x5f81u, 0x9feau, 0x0f80u};
    unsigned saved = _mm_getcsr();
    int ok = 1;
    for (size_t i = 0; ok && i < sizeof(controls)/sizeof(controls[0]); ++i) {
        _mm_setcsr(controls[i]);
        int code = Tcl_EvalObjv(interp, 3, args, TCL_EVAL_GLOBAL);
        unsigned after = _mm_getcsr();
        _mm_setcsr(saved);
        Tcl_Size count;
        Tcl_Obj **items;
        ok = code == TCL_OK && after == controls[i] &&
            Tcl_ListObjGetElements(interp, Tcl_GetObjResult(interp), &count, &items) == TCL_OK &&
            count == 2 && strcmp(Tcl_GetString(items[0]), "ok") == 0 &&
            items[1]->typePtr == args[1]->typePtr;
        if (ok) {
            uint64_t word;
            memcpy(&word, &items[1]->internalRep.doubleValue, sizeof(word));
            ok = word == UINT64_C(0x3f847ae147ae147c) &&
                !Tcl_HasStringRep(args[1]) && !Tcl_HasStringRep(args[2]);
        }
        Tcl_ResetResult(interp);
    }
    /* A nested native call can arrive with a retained interpreter result.
     * Also try an argument itself as that result, bypassing the eval reset. */
    Tcl_CmdInfo native;
    Tcl_Obj *empty = Tcl_NewObj();
    Tcl_IncrRefCount(empty);
    Tcl_Obj *prior[] = {empty, args[1]};
    const Tcl_ObjType *double_type = args[1]->typePtr;
    ok = ok && Tcl_GetCommandInfo(interp, command, &native) && native.objProc2 != NULL;
    for (size_t i = 0; ok && i < 2; ++i) {
        Tcl_SetObjResult(interp, prior[i]);
        ok = native.objProc2(native.objClientData2, interp, 3, args) == TCL_OK &&
            Tcl_GetObjResult(interp) != prior[i] && prior[i]->refCount == 1 &&
            empty->typePtr == NULL && empty->length == 0 &&
            args[1]->typePtr == double_type && !Tcl_HasStringRep(args[1]) &&
            args[1]->internalRep.doubleValue == 0.1;
        Tcl_ResetResult(interp);
    }
    Tcl_DecrRefCount(empty);
    for (size_t i = 0; i < 3; ++i) {Tcl_DecrRefCount(args[i]);}
    return ok;
#else
    (void)interp;
    return 1;
#endif
}

static int
check_civil_time(Tcl_Interp *interp, const char *mode, Tcl_Obj *value, const char *expected)
{
    Tcl_Obj *args[3];
    int count = 0;
    args[count++] = Tcl_NewStringObj(mode ? "::machteld::x::civilTime" : "::machteld::x::normalizeInstant", -1);
    if (mode) args[count++] = Tcl_NewStringObj(mode, -1);
    args[count++] = value;
    for (int i = 0; i < count; ++i) Tcl_IncrRefCount(args[i]);
    const Tcl_ObjType *type = value->typePtr;
    int had_string = Tcl_HasStringRep(value);
    int code = Tcl_EvalObjv(interp, count, args, TCL_EVAL_GLOBAL);
    int ok = code == TCL_OK && !strcmp(Tcl_GetStringResult(interp), expected) &&
            value->typePtr == type && Tcl_HasStringRep(value) == had_string;
    if (!ok) fprintf(stderr, "%s returned %s\n", mode ? mode : "normalizeInstant", Tcl_GetStringResult(interp));
    Tcl_ResetResult(interp);
    for (int i = 0; i < count; ++i) Tcl_DecrRefCount(args[i]);
    return ok;
}

int
main(int argc, char **argv)
{
    (void)argc;
    Tcl_FindExecutable(argv[0]);
    Tcl_Interp *interp = Tcl_CreateInterp();
    int ok = Tcl_Eval(interp, "namespace eval ::machteld {}") == TCL_OK &&
        MachteldCompilerGuard_Init(interp) == TCL_OK;
    ok = check_civil_time(interp, "parts", Tcl_NewStringObj("2400-02-29T23:09:07.000010000", -1),
            "2400 2 29 23 9 7 00001") && ok;
    ok = check_civil_time(interp, "parts", Tcl_NewWideIntObj(123), "") && ok;
    ok = check_civil_time(interp, "parts", Tcl_NewStringObj("2024-02-29T09:08:0\0", 19), "") && ok;
    ok = check_civil_time(interp, "instant", Tcl_NewStringObj("1900-02-29T00:00:00.000000000Z", -1), "") && ok;
    ok = check_civil_time(interp, "instant", Tcl_NewStringObj("2000-02-29T00:00:00.000000000Z", -1), "1") && ok;
    ok = check_civil_time(interp, "local_datetime", Tcl_NewStringObj("0001-01-01T00:00:00.1", -1), "1") && ok;
    ok = check_civil_time(interp, "local_datetime", Tcl_NewStringObj("0001-01-01T00:00:00.10", -1), "") && ok;
    ok = check_civil_time(interp, NULL, Tcl_NewStringObj("2000-03-01T05:44:00.1+05:45", -1),
            "2000-02-29T23:59:00.100000000Z") && ok;
    ok = check_civil_time(interp, NULL, Tcl_NewWideIntObj(7), "") && ok;
    ok = check_civil_time(interp, NULL, Tcl_NewStringObj("2000-01-01T12:00:00-00:00", -1), "") && ok;
    ok = check_civil_time(interp, NULL, Tcl_NewStringObj("9999-12-31T23:59:59-00:01", -1), "") && ok;
    ok = check_binary64_print_words(interp) && ok;
    ok = check_binary64_operator_controls(interp) && ok;
    ok = check_text_length(interp, Tcl_NewStringObj("a\0b\xc0\x80", 5), 4) && ok;
    ok = check_text_length(interp, Tcl_NewStringObj("a\xf0\x9f\x9a\x80" "b", 6), 3) && ok;
    ok = check_text_length(interp, Tcl_NewStringObj("\xed\xa0\x80\0", 4), 2) && ok;
    ok = check_text_length(interp, Tcl_NewStringObj("\xed\xb0\x80", 3), 1) && ok;
    unsigned char octets[256];
    for (int i = 0; i < 256; ++i) {octets[i] = (unsigned char)i;}
    ok = check_text_length(interp, Tcl_NewByteArrayObj(octets, 256), 256) && ok;
    ok = check_text_length(interp, Tcl_NewWideIntObj(12345), 5) && ok;
    Tcl_Obj *element = Tcl_NewStringObj("a b", -1);
    ok = check_text_length(interp, Tcl_NewListObj(1, &element), 5) && ok;
    Tcl_Obj *word = Tcl_NewStringObj("17", -1);
    Tcl_IncrRefCount(word);
    double number;
    ok = ok && Tcl_GetDoubleFromObj(interp, word, &number) == TCL_OK && number == 17.0 &&
        retained(interp, word, word->typePtr, "17");
    /* Ordinary coercion can cache an integer for "17". Store an equally valid
     * double representation explicitly, preserving the exact lexical digits. */
    Tcl_Obj *real = Tcl_NewDoubleObj(17.0);
    Tcl_IncrRefCount(real);
    const Tcl_ObjType *double_type = real->typePtr;
    Tcl_StoreInternalRep(word, double_type, Tcl_FetchInternalRep(real, double_type));
    ok = ok && strcmp(Tcl_GetString(word), "17") == 0 && retained(interp, word, double_type, "17");
    ok = record_retained(interp, word) && ok;
    Tcl_DecrRefCount(real);
    Tcl_DecrRefCount(word);
    Tcl_Obj *bytes = Tcl_NewByteArrayObj((const unsigned char *)"009", 3);
    ok = retained(interp, bytes, bytes->typePtr, "9") && ok;
    Tcl_Obj *boolean = Tcl_NewBooleanObj(1);
    ok = retained(interp, boolean, boolean->typePtr, "1") && ok;
    ok = call_command(interp, "::machteld::x::guardInteger", Tcl_NewStringObj("17\0tail", 7),
            TCL_ERROR, "expected int at amounts") && ok;
    ok = Tcl_Eval(interp,
            "catch {::machteld::x::guardInteger 0x17 amounts} message options;"
            "list $message [dict get $options -errorcode]") == TCL_OK &&
            strcmp(Tcl_GetStringResult(interp), "{expected int at amounts} {APPCOMPILER ARGUMENT TYPE}") == 0 && ok;
    Tcl_Obj *bounds = Tcl_NewStringObj("999999999999999999 1000000000000000000 -9223372036854775808 9223372036854775808", -1);
    ok = call(interp, bounds, TCL_OK, "999999999999999999 1000000000000000000 -9223372036854775808 9223372036854775808") && ok;
    /* Both encodings of embedded NUL must merge. Construct the raw spelling
     * directly so this remains testable even after newer JSON fixed its output. */
    ok = check_key(interp, Tcl_NewStringObj("a\0b", 3), TCL_OK, "a\xc0\x80" "b", 4, 1) && ok;
    ok = check_key(interp, Tcl_NewStringObj("a\xc0\x80" "b", 4), TCL_OK, "a\xc0\x80" "b", 4, 1) && ok;
    ok = check_key(interp, Tcl_NewByteArrayObj((const unsigned char *)"raw", 3), TCL_OK, "raw", 3, 0) && ok;
    ok = check_key(interp, Tcl_NewStringObj("\xed\xa0\x80", 3), TCL_OK, "\xed\xa0\x80", 3, 0) && ok;
    ok = check_key(interp, Tcl_NewStringObj("\xed\xa0\x80\0", 4), TCL_ERROR, NULL, 0, 1) && ok;
    /* At 25 bytes the modified NUL spans offsets 23 and 24. A last 0xc0
     * is not a NUL without its continuation byte. */
    for (Tcl_Size n = 23; n <= 25; ++n) {
        char raw[25], normalized[26];
        memset(raw, 'x', (size_t)n);
        memset(normalized, 'x', (size_t)n);
        raw[n - 1] = 0;
        normalized[n - 1] = (char)0xc0;
        normalized[n] = (char)0x80;
        ok = check_key(interp, Tcl_NewStringObj(raw, n), TCL_OK, normalized, n + 1, 1) && ok;
        ok = check_key(interp, Tcl_NewStringObj(normalized + 1, n), TCL_OK, normalized + 1, n, 1) && ok;
        ok = check_key(interp, Tcl_NewStringObj(normalized, n), TCL_OK, normalized, n, 0) && ok;
    }
    Tcl_Interp *peer = Tcl_CreateInterp();
    ok = Tcl_Eval(peer, "namespace eval ::machteld {}") == TCL_OK &&
        MachteldCompilerGuard_Init(peer) == TCL_OK && MachteldCompilerGuard_Init(peer) == TCL_OK &&
        fresh_integer(peer, Tcl_NewWideIntObj(87), "87") && ok;
    Tcl_DeleteInterp(peer);
    ok = check_decimal_operands(interp) && ok;
    ok = fresh_integer(interp, Tcl_NewWideIntObj(987654321), "987654321") && ok;
    const char *big_text = "1844674407370955161787654321";
    Tcl_Obj *big = Tcl_NewStringObj(big_text, -1);
    Tcl_IncrRefCount(big);
    int kind;
    void *number_value;
    if (Tcl_GetNumberFromObj(interp, big, &number_value, &kind) == TCL_OK && kind == TCL_NUMBER_BIG) {
        Tcl_InvalidateStringRep(big);
        ok = fresh_integer(interp, big, big_text) && ok;
    } else {
        ok = 0;
    }
    Tcl_DecrRefCount(big);
    const char *spellings[] = {"0x10", "+017", "-00017"};
    const char *results[] = {"expected int at amounts.0", "17", "-17"};
    for (size_t i = 0; i < sizeof spellings / sizeof spellings[0]; ++i) {
        Tcl_Obj *cached_int = Tcl_NewStringObj(spellings[i], -1);
        Tcl_IncrRefCount(cached_int);
        Tcl_WideInt numeric;
        ok = Tcl_GetWideIntFromObj(interp, cached_int, &numeric) == TCL_OK && ok;
        Tcl_Obj *list = Tcl_NewListObj(1, &cached_int);
        ok = call(interp, list, i == 0 ? TCL_ERROR : TCL_OK, results[i]) && ok;
        ok = strcmp(Tcl_GetString(cached_int), spellings[i]) == 0 && ok;
        Tcl_DecrRefCount(cached_int);
    }
    Tcl_DeleteInterp(interp);
    Tcl_Finalize();
    if (!ok) {
        fputs("compiler guard or map-key normalization failed\n", stderr);
        return 1;
    }
    puts("compiler guard and map-key normalization retained each input and its references");
    return 0;
}
