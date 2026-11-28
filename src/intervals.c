/* Batch complement of inclusive, signed 64-bit integer intervals. */
#include <stdint.h>
#include <stdlib.h>
#include <tcl.h>

typedef struct {
    Tcl_WideInt low;
    Tcl_WideInt high;
} Interval;

static int
CompareStart(const void *left, const void *right)
{
    const Interval *a = left;
    const Interval *b = right;
    return (a->low > b->low) - (a->low < b->low);
}

static int
Fail(Tcl_Interp *interp, const char *code, const char *message)
{
    if (message != NULL) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(message, -1));
    }
    Tcl_SetErrorCode(interp, "MACHTELD", "INTERVALS", code, NULL);
    return TCL_ERROR;
}

/* The list takes a reference only after it has room for the new item. */
static int
AppendNew(Tcl_Interp *interp, Tcl_Obj *result, Tcl_Obj *item)
{
    Tcl_IncrRefCount(item);
    int status = Tcl_ListObjAppendElement(interp, result, item);
    Tcl_DecrRefCount(item);
    return status;
}

static int
AppendGap(Tcl_Interp *interp, Tcl_Obj *result, Tcl_WideInt low, Tcl_WideInt high,
          int pairs)
{
    if (pairs) {
        Tcl_Obj *items[] = {Tcl_NewWideIntObj(low), Tcl_NewWideIntObj(high)};
        return AppendNew(interp, result, Tcl_NewListObj(2, items));
    }
    if (AppendNew(interp, result, Tcl_NewWideIntObj(low)) != TCL_OK) {
        return TCL_ERROR;
    }
    return AppendNew(interp, result, Tcl_NewWideIntObj(high));
}

static int
EmitGaps(Tcl_Interp *interp, Tcl_Obj *result, const Interval *covered, Tcl_Size count,
         Tcl_WideInt next, Tcl_WideInt upper, int pairs)
{
    for (Tcl_Size i = 0; i < count; ++i) {
        if (covered[i].high < next) {
            continue;
        }
        if (covered[i].low > next &&
            AppendGap(interp, result, next, covered[i].low - 1, pairs) != TCL_OK) {
            return TCL_ERROR;
        }
        if (covered[i].high >= upper) {
            return TCL_OK;
        }
        /* The upper-bound check keeps the increment in the signed range. */
        next = covered[i].high + 1;
    }
    return AppendGap(interp, result, next, upper, pairs);
}

static int
IntervalsCmd(void *clientData, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    static const char *const operations[] = {"gaps", NULL};
    static const char *const options[] = {"-pairs", NULL};
    int index;
    int pairs = objc == 6;
    (void)clientData;
    if (objc < 2 || (objc != 5 && !pairs)) {
        Tcl_WrongNumArgs(interp, 1, objv, "gaps ?-pairs? lower upper endpoints");
        return Fail(interp, "usage", NULL);
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], operations, "operation", TCL_EXACT, &index) != TCL_OK ||
        (pairs && Tcl_GetIndexFromObj(interp, objv[2], options, "option", TCL_EXACT, &index) != TCL_OK)) {
        return Fail(interp, "usage", NULL);
    }

    Tcl_WideInt lower, upper;
    Tcl_Obj **endpoints;
    Tcl_Size length;
    if (Tcl_GetWideIntFromObj(interp, objv[objc - 3], &lower) != TCL_OK ||
        Tcl_GetWideIntFromObj(interp, objv[objc - 2], &upper) != TCL_OK ||
        Tcl_ListObjGetElements(interp, objv[objc - 1], &length, &endpoints) != TCL_OK) {
        return Fail(interp, "input", NULL);
    }
    if (lower > upper) {
        return Fail(interp, "input", "lower bound exceeds upper bound");
    }
    if (length % 2 != 0) {
        return Fail(interp, "input", "expected an even number of interval endpoints");
    }

    Interval *covered = NULL;
    Tcl_Size capacity = length / 2;
    if (capacity > 0 &&
        ((size_t)capacity > (size_t)TCL_SIZE_MAX / sizeof(*covered) ||
         (covered = Tcl_AttemptAlloc((size_t)capacity * sizeof(*covered))) == NULL)) {
        return Fail(interp, "memory", "cannot allocate interval workspace");
    }
    Tcl_Size count = 0;
    int sorted = 1;
    int status = TCL_OK;
    for (Tcl_Size i = 0; i < length; i += 2) {
        Tcl_WideInt low, high;
        if (Tcl_GetWideIntFromObj(interp, endpoints[i], &low) != TCL_OK ||
            Tcl_GetWideIntFromObj(interp, endpoints[i + 1], &high) != TCL_OK) {
            status = Fail(interp, "input", NULL);
            break;
        }
        if (low > high) {
            status = Fail(interp, "input", "interval start exceeds its end");
            break;
        }
        if (high < lower || low > upper) {
            continue;
        }
        if (count > 0 && low < covered[count - 1].low) {
            sorted = 0;
        }
        covered[count++] = (Interval){low, high};
    }
    if (status == TCL_OK) {
        if (!sorted) {
            qsort(covered, (size_t)count, sizeof(*covered), CompareStart);
        }
        Tcl_Obj *result = Tcl_NewListObj(0, NULL);
        Tcl_IncrRefCount(result);
        status = EmitGaps(interp, result, covered, count, lower, upper, pairs);
        if (status == TCL_OK) {
            Tcl_SetObjResult(interp, result);
        } else {
            Fail(interp, "memory", NULL);
        }
        Tcl_DecrRefCount(result);
    }
    if (covered != NULL) {
        Tcl_Free(covered);
    }
    return status;
}

int
Machteldintervals_Init(Tcl_Interp *interp)
{
    return Tcl_CreateObjCommand(interp, "::machteld::intervals", IntervalsCmd, NULL, NULL)
            ? TCL_OK : TCL_ERROR;
}
