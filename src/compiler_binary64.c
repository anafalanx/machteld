/* Private X arithmetic. Operands run in Tcl before entry and the caller's
 * floating-point environment is restored before a source-mapped failure. */
#include <tcl.h>
#include <float.h>

#if defined(_WIN64) && (defined(_M_X64) || defined(__x86_64__)) && \
    !defined(__clang__) && (defined(__GNUC__) || defined(_MSC_VER)) && \
    !defined(__FAST_MATH__) && !defined(_M_FP_FAST) && \
    FLT_RADIX == 2 && DBL_MANT_DIG == 53 && DBL_MAX_EXP == 1024 && DBL_MIN_EXP == -1021
#define MACHTELD_BINARY64_OPERATORS 1
#include <emmintrin.h>
#include <stdint.h>
#include <string.h>

typedef enum {
    Add, Subtract, Multiply, Divide, Negate, Less, LessEqual, Greater, GreaterEqual, Equal, NotEqual
} Operation;

typedef struct {
    const Tcl_ObjType *double_type;
    Operation operation;
} BinaryOperator;

static const char *const operator_names[] = {"add", "subtract", "multiply", "divide", "negate",
    "less", "lessEqual", "greater", "greaterEqual", "equal", "notEqual", NULL};

static const uint64_t sign_bit = UINT64_C(0x8000000000000000);
static const uint64_t infinity = UINT64_C(0x7ff0000000000000);

static int
read_word(Tcl_Interp *interp, const Tcl_ObjType *double_type, Tcl_Obj *value, uint64_t *word)
{
    if (value->typePtr == double_type) {
        memcpy(word, &value->internalRep.doubleValue, sizeof(*word));
        return TCL_OK;
    }
    /* A Tcl read trace can replace a checked variable. Preserve its borrowed
     * representation when the usual Tcl numeric coercion is needed. */
    Tcl_Obj *copy = Tcl_DuplicateObj(value);
    Tcl_IncrRefCount(copy);
    void *number;
    int kind;
    int code = Tcl_GetNumberFromObj(interp, copy, &number, &kind);
    if (code == TCL_OK && kind == TCL_NUMBER_DOUBLE) {memcpy(word, number, sizeof(*word));}
    else {code = TCL_ERROR;}
    Tcl_DecrRefCount(copy);
    return code;
}

static uint64_t
canonical_zero(uint64_t word)
{
    return (word & ~sign_bit) == 0 ? 0 : word;
}

static uint64_t
ordered_word(uint64_t word)
{
    word = canonical_zero(word);
    return (word & sign_bit) ? ~word : (word ^ sign_bit);
}

/* Tcl normally supplies an unshared, empty result object. Direct calls from
 * another operator can leave a shared, typed or nonempty result instead. */
static Tcl_Obj *
numeric_result_object(Tcl_Interp *interp)
{
    Tcl_Obj *result = Tcl_GetObjResult(interp);
    if (!Tcl_IsShared(result) && result->typePtr == NULL && result->bytes != NULL && result->length == 0) {
        return result;
    }
    return Tcl_NewObj();
}

static int
return_comparison(Tcl_Interp *interp, Operation op, uint64_t left, uint64_t right)
{
    left = ordered_word(left);
    right = ordered_word(right);
    int answer;
    switch (op) {
    case Less:         answer = left < right; break;
    case LessEqual:    answer = left <= right; break;
    case Greater:      answer = left > right; break;
    case GreaterEqual: answer = left >= right; break;
    case Equal:        answer = left == right; break;
    default:           answer = left != right; break;
    }
    Tcl_Obj *result = numeric_result_object(interp);
    Tcl_SetBooleanObj(result, answer);
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
}

static int
return_number(Tcl_Interp *interp, uint64_t word, int tagged)
{
    word = canonical_zero(word);
    double number;
    memcpy(&number, &word, sizeof(number));
    Tcl_Obj *result = numeric_result_object(interp);
    if (tagged) {
        Tcl_Obj *items[] = {Tcl_NewStringObj("ok", -1), Tcl_NewDoubleObj(number)};
        Tcl_SetListObj(result, 2, items);
    } else {
        Tcl_SetDoubleObj(result, number);
    }
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
}

/* Keep this one operation inside the MXCSR interval even with optimization.
 * No Tcl callback or object conversion runs in the interval. */
#ifdef _MSC_VER
__declspec(noinline)
#else
__attribute__((noinline, noclone))
#endif
static uint64_t
calculate(Operation op, uint64_t left, uint64_t right)
{
    __m128d a = _mm_castsi128_pd(_mm_cvtsi64_si128((long long)left));
    __m128d b = _mm_castsi128_pd(_mm_cvtsi64_si128((long long)right));
    switch (op) {
    case Add:      a = _mm_add_sd(a, b); break;
    case Subtract: a = _mm_sub_sd(a, b); break;
    case Multiply: a = _mm_mul_sd(a, b); break;
    default:       a = _mm_div_sd(a, b); break;
    }
    return (uint64_t)_mm_cvtsi128_si64(_mm_castpd_si128(a));
}

static int
problem(Tcl_Interp *interp, int zero_divisor, Tcl_Size objc, Tcl_Obj *const objv[])
{
    Tcl_Obj *details = Tcl_NewDictObj();
    Tcl_DictObjPut(NULL, details, Tcl_NewStringObj("code", -1),
        Tcl_NewStringObj(zero_divisor ? "DIVIDE_BY_ZERO" : "BINARY64_OVERFLOW", -1));
    Tcl_DictObjPut(NULL, details, Tcl_NewStringObj("message", -1),
        Tcl_NewStringObj(zero_divisor ? "division by zero" : "operation exceeds the finite binary64 range", -1));
    Tcl_Obj *items[] = {Tcl_NewStringObj("err", -1), details};
    Tcl_Obj *result = Tcl_NewListObj(2, items);
    if (objc == 3) {
        Tcl_SetObjResult(interp, result);
        return TCL_OK;
    }
    /* Use the existing runtime's propagation, including its return level
     * and the innermost ? source span, in the application's original frame. */
    Tcl_Obj *call[] = {objv[3], result, objv[4]};
    Tcl_IncrRefCount(result);
    int code = Tcl_EvalObjv(interp, 3, call, 0);
    Tcl_DecrRefCount(result);
    return code;
}

/* Tcl read traces may inject a non-number or infinity after entry validation.
 * Ask the same Tcl operator to diagnose the captured operands. This keeps
 * left/right wording, error codes and effects without rereading a variable. */
static int
unchecked_operator(Tcl_Interp *interp, Operation op, Tcl_Size objc, Tcl_Obj *const objv[])
{
    static const char *const symbols[] = {"+", "-", "*", "/", "neg", "<", "<=", ">", ">=", "==", "!="};
    /* Retain Tcl's exact mixed integer/double comparisons, integer division,
     * string ordering, and argument-specific diagnostics in this cold path.
     * The literal lambda never evaluates application-supplied script. */
    static const char fallback[] =
        "{op a b mode} {\n"
        "if {$op eq {neg}} {return [::tcl::mathop::- 0.0 $a]}\n"
        "if {$op in {< <= > >= == !=}} {return [::tcl::mathop::$op $a $b]}\n"
        "if {$op eq {/} && $b == 0.0} {return {err {code DIVIDE_BY_ZERO message {division by zero}}}}\n"
        "set n [::tcl::mathop::$op $a $b]\n"
        "if {abs($n) == Inf} {return {err {code BINARY64_OVERFLOW message {operation exceeds the finite binary64 range}}}}\n"
        "if {$mode == 6} {return [list ok $n]}\n"
        "if {$mode == 5 && $op ne {/}} {return [list ok [expr {0.0 + $n}]]}\n"
        "return [list ok [expr {$n == 0.0 ? 0.0 : $n}]]\n"
        "} ::";
    Tcl_Obj *args[] = {Tcl_NewStringObj("::apply", -1), Tcl_NewStringObj(fallback, -1),
        Tcl_NewStringObj(symbols[op], -1), Tcl_DuplicateObj(objv[1]),
        op == Negate ? Tcl_NewObj() : Tcl_DuplicateObj(objv[2]), Tcl_NewWideIntObj(objc)};
    for (size_t i = 0; i < 6; ++i) {Tcl_IncrRefCount(args[i]);}
    int code = Tcl_EvalObjv(interp, 6, args, 0);
    for (size_t i = 0; i < 6; ++i) {Tcl_DecrRefCount(args[i]);}
    if (code != TCL_OK || objc < 5) {return code;}
    Tcl_Obj *result = Tcl_GetObjResult(interp);
    Tcl_Obj *call[] = {objv[3], result, objv[4]};
    Tcl_IncrRefCount(result);
    code = Tcl_EvalObjv(interp, 3, call, 0);
    Tcl_DecrRefCount(result);
    return code;
}

static int
apply_operator(void *data, Tcl_Interp *interp, Tcl_Size objc, Tcl_Obj *const objv[])
{
    const BinaryOperator *self = data;
    Operation op = self->operation;
    if (op == Negate ? objc != 2 : (objc != 3 && !(op <= Divide && objc == 5) &&
            !(op <= Multiply && objc == 6 && strcmp(Tcl_GetString(objv[5]), "raw") == 0))) {
        Tcl_WrongNumArgs(interp, 1, objv, op == Negate ? "number" :
            (op <= Multiply ? "left right ?propagate location ?raw??" :
             op == Divide ? "left right ?propagate location?" : "left right"));
        return TCL_ERROR;
    }
    uint64_t left, right = 0;
    /* The existing binaryArithmetic path checks the divisor first. The Tcl
     * arguments have already been evaluated left-to-right by the caller. */
    if (op == Divide) {
        if (read_word(interp, self->double_type, objv[2], &right) != TCL_OK) {
            Tcl_ResetResult(interp);
            return unchecked_operator(interp, op, objc, objv);
        }
        if (canonical_zero(right) == 0) {return problem(interp, 1, objc, objv);}
    }
    if (read_word(interp, self->double_type, objv[1], &left) != TCL_OK ||
        (op != Negate && op != Divide && read_word(interp, self->double_type, objv[2], &right) != TCL_OK) ||
        (left & ~sign_bit) >= infinity || (right & ~sign_bit) >= infinity) {
        Tcl_ResetResult(interp);
        return unchecked_operator(interp, op, objc, objv);
    }

    if (op >= Less) {return return_comparison(interp, op, left, right);}

    uint64_t word;
    if (op == Negate) {
        word = left ^ sign_bit;
    } else {
        unsigned saved = _mm_getcsr();
        if ((saved & 0xffc0u) != 0x1f80u) {_mm_setcsr(0x1f80u);}
        volatile uint64_t result = calculate(op, left, right);
        if (_mm_getcsr() != saved) {_mm_setcsr(saved);}
        word = result;
        if ((word & ~sign_bit) >= infinity) {return problem(interp, 0, objc, objv);}
    }
    return return_number(interp, word, op != Negate && objc == 3);
}

enum { RawInner = 1, PropagatedOuter = 2, RawOuter = 4 };

/* Evaluate left OUTER (middle INNER right) after Tcl has finished all three
 * source reads. The inner result must round to binary64 before OUTER. No
 * Tcl operation runs between the two arithmetic instructions. */
static int
right_pair(void *data, Tcl_Interp *interp, Tcl_Size objc, Tcl_Obj *const objv[])
{
    const Tcl_ObjType *type = data;
    if (objc != 10) {
        Tcl_WrongNumArgs(interp, 1, objv, "left middle right propagate innerLocation outerLocation outerOp innerOp flags");
        return TCL_ERROR;
    }
    int outer, inner, flags;
    if (Tcl_GetIndexFromObj(interp, objv[7], operator_names, "outer operation", TCL_EXACT, &outer) != TCL_OK ||
        Tcl_GetIndexFromObj(interp, objv[8], operator_names, "inner operation", TCL_EXACT, &inner) != TCL_OK ||
        Tcl_GetIntFromObj(interp, objv[9], &flags) != TCL_OK) {return TCL_ERROR;}
    if (inner > Multiply || outer == Divide || outer == Negate || flags < 0 || flags > 7 ||
        ((flags & PropagatedOuter) && outer > Multiply) || ((flags & RawOuter) && !(flags & PropagatedOuter))) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("invalid checked binary64 pair", -1));
        return TCL_ERROR;
    }
    uint64_t words[3];
    for (int i = 0; i < 3; ++i) {
        if (objv[i+1]->typePtr == type) {
            memcpy(&words[i], &objv[i+1]->internalRep.doubleValue, sizeof(words[i]));
            if ((words[i] & ~sign_bit) < infinity) {continue;}
        }
        /* A Tcl trace can replace a promised double. Use both original
         * operation handlers, including their numeric coercion order. */
        BinaryOperator first = {type, (Operation)inner};
        BinaryOperator second = {type, (Operation)outer};
        Tcl_Obj *raw = Tcl_NewStringObj("raw", -1);
        Tcl_IncrRefCount(raw);
        Tcl_Obj *args[] = {objv[0], objv[2], objv[3], objv[4], objv[5], raw};
        int code = apply_operator(&first, interp, (flags & RawInner) ? 6 : 5, args);
        if (code == TCL_OK) {
            Tcl_Obj *result = Tcl_GetObjResult(interp);
            Tcl_IncrRefCount(result);
            args[1] = objv[1]; args[2] = result; args[4] = objv[6];
            Tcl_Size count = (flags & RawOuter) ? 6 : (flags & PropagatedOuter) ? 5 : 3;
            code = apply_operator(&second, interp, count, args);
            Tcl_DecrRefCount(result);
        }
        Tcl_DecrRefCount(raw);
        return code;
    }
    unsigned saved = _mm_getcsr();
    if ((saved & 0xffc0u) != 0x1f80u) {_mm_setcsr(0x1f80u);}
    volatile uint64_t mid = calculate((Operation)inner, words[1], words[2]);
    int failed_inner = (mid & ~sign_bit) >= infinity;
    volatile uint64_t result = 0;
    if (!failed_inner && outer <= Multiply) {
        result = calculate((Operation)outer, words[0], canonical_zero(mid));
    }
    if (_mm_getcsr() != saved) {_mm_setcsr(saved);}
    if (failed_inner || (outer <= Multiply && (result & ~sign_bit) >= infinity)) {
        Tcl_Obj *args[] = {objv[0], objv[1], objv[2], objv[4], failed_inner ? objv[5] : objv[6]};
        return problem(interp, 0, failed_inner || (flags & PropagatedOuter) ? 5 : 3, args);
    }
    if (outer >= Less) {return return_comparison(interp, (Operation)outer, words[0], mid);}
    return return_number(interp, result, !(flags & PropagatedOuter));
}
#endif

int
MachteldBinary64Operators_Init(Tcl_Interp *interp)
{
#ifdef MACHTELD_BINARY64_OPERATORS
    const Tcl_ObjType *type = Tcl_GetObjType("double");
    if (type == NULL) {return TCL_OK;}
    const char *name = "::machteld::x::binary64v1";
    Tcl_Namespace *ns = Tcl_FindNamespace(interp, name, NULL, TCL_GLOBAL_ONLY);
    if (!ns && !(ns = Tcl_CreateNamespace(interp, name, NULL, NULL))) {return TCL_ERROR;}
    for (int i = 0; i <= NotEqual; ++i) {
        BinaryOperator *config = (BinaryOperator *)Tcl_Alloc(sizeof(*config));
        config->double_type = type;
        config->operation = (Operation)i;
        Tcl_DString path;
        Tcl_DStringInit(&path);
        Tcl_DStringAppend(&path, name, -1);
        Tcl_DStringAppend(&path, "::", 2);
        Tcl_DStringAppend(&path, operator_names[i], -1);
        Tcl_Command command = Tcl_CreateObjCommand2(interp, Tcl_DStringValue(&path), apply_operator, config, Tcl_Free);
        Tcl_DStringFree(&path);
        if (!command) {Tcl_Free(config); return TCL_ERROR;}
    }
    if (!Tcl_CreateObjCommand2(interp, "::machteld::x::binary64v1::rightPair", right_pair, (void *)type, NULL) ||
        Tcl_Export(interp, ns, "rightPair", 0) != TCL_OK) {return TCL_ERROR;}
    return Tcl_Export(interp, ns, "add", 0);
#else
    (void)interp;
    return TCL_OK;
#endif
}
