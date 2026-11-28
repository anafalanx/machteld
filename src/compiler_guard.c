/* Private acceleration for the X compiler's Tcl boundary. */
#include <tcl.h>
#include <string.h>
#include <stdio.h>
#include <float.h>
#include <stdint.h>
extern int MachteldBinary64Operators_Init(Tcl_Interp *interp);

#if defined(_WIN64) && (defined(_M_X64) || defined(__x86_64__)) && \
    (defined(_UCRT) || defined(_MSC_VER)) && defined(_CRT_INTERNAL_PRINTF_STANDARD_ROUNDING) && \
    !defined(__FAST_MATH__) && !defined(_M_FP_FAST) && \
    FLT_RADIX == 2 && DBL_MANT_DIG == 53 && DBL_MAX_EXP == 1024 && DBL_MIN_EXP == -1021
#define MACHTELD_UCRT_BINARY64_PRINT 1
#include <fenv.h>
#include <locale.h>
#include <stdarg.h>
#include <xmmintrin.h>
#endif

static int
reject(Tcl_Interp *interp, Tcl_Obj *path, Tcl_Size index)
{
    Tcl_Obj *message = Tcl_NewStringObj(
        index < 0 ? "expected list<int> at " : "expected int at ", -1);
    Tcl_AppendObjToObj(message, path);
    if (index >= 0) {
        Tcl_AppendPrintfToObj(message, ".%lld", (long long)index);
    }
    Tcl_SetObjResult(interp, message);
    Tcl_SetErrorCode(interp, "APPCOMPILER", "ARGUMENT", "TYPE", NULL);
    return TCL_ERROR;
}

typedef struct {
    const Tcl_ObjType *integer;
    const Tcl_ObjType *bignum;
} IntegerTypes;

static void
free_integer_types(void *data, Tcl_Interp *interp)
{
    (void)interp;
    Tcl_Free(data);
}

/* Tcl does not register these core types by name. Capture the types of two
 * known numbers once per interpreter; both commands share its lifetime. */
static IntegerTypes *
integer_types(Tcl_Interp *interp)
{
    const char *key = "machteld::compiler_guard::integer_types";
    IntegerTypes *types = Tcl_GetAssocData(interp, key, NULL);
    if (types) {return types;}
    Tcl_Obj *small = Tcl_NewWideIntObj(1);
    Tcl_Obj *big = Tcl_NewStringObj("18446744073709551616", -1);
    Tcl_IncrRefCount(small);
    Tcl_IncrRefCount(big);
    int kind;
    void *number;
    if (Tcl_GetNumberFromObj(interp, big, &number, &kind) == TCL_OK && kind == TCL_NUMBER_BIG) {
        types = (IntegerTypes *)Tcl_Alloc(sizeof(*types));
        types->integer = small->typePtr;
        types->bignum = big->typePtr;
        Tcl_SetAssocData(interp, key, free_integer_types, types);
    }
    Tcl_DecrRefCount(big);
    Tcl_DecrRefCount(small);
    return types;
}

/* Return an independent, owned integer. An integer with no string can only
 * generate canonical decimal text. Every existing spelling still takes the
 * lexical path, including cached octal and hexadecimal interpretations. */
static Tcl_Obj *
checked_integer(const IntegerTypes *types, Tcl_Obj *item)
{
    if ((item->typePtr == types->integer || item->typePtr == types->bignum) &&
            !Tcl_HasStringRep(item)) {
        Tcl_Obj *copy = Tcl_DuplicateObj(item);
        Tcl_IncrRefCount(copy);
        return copy;
    }
    Tcl_Size length;
    const char *bytes = Tcl_GetStringFromObj(item, &length);
    int negative = length && bytes[0] == '-';
    Tcl_Size first = negative || (length && bytes[0] == '+') ? 1 : 0;
    if (first == length) {
        return NULL;
    }
    while (first < length && bytes[first] == '0') {
        ++first;
    }

    Tcl_Obj *number;
    /* Every magnitude of at most 18 decimal digits fits a Tcl_WideInt,
     * including its negation. Leading zeroes never count towards that limit. */
    if (length - first <= 18) {
        Tcl_WideInt magnitude = 0;
        for (Tcl_Size i = first; i < length; ++i) {
            if (bytes[i] < '0' || bytes[i] > '9') {
                return NULL;
            }
            magnitude = 10 * magnitude + (bytes[i] - '0');
        }
        number = Tcl_NewWideIntObj(negative ? -magnitude : magnitude);
        Tcl_IncrRefCount(number);
        return number;
    }
    for (Tcl_Size i = first; i < length; ++i) {
        if (bytes[i] < '0' || bytes[i] > '9') {
            return NULL;
        }
    }
    number = Tcl_NewStringObj(negative ? "-" : "", negative ? 1 : 0);
    Tcl_AppendToObj(number, bytes + first, length - first);
    Tcl_IncrRefCount(number);
    void *value;
    int type;
    if (Tcl_GetNumberFromObj(NULL, number, &value, &type) != TCL_OK ||
        (type != TCL_NUMBER_INT && type != TCL_NUMBER_BIG)) {
        Tcl_DecrRefCount(number);
        return NULL;
    }
    return number;
}

static int
guard_integer(void *data, Tcl_Interp *interp, Tcl_Size objc, Tcl_Obj *const objv[])
{
    if (objc != 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "value path");
        return TCL_ERROR;
    }
    Tcl_Obj *number = checked_integer(data, objv[1]);
    if (!number) {
        Tcl_Obj *message = Tcl_NewStringObj("expected int at ", -1);
        Tcl_AppendObjToObj(message, objv[2]);
        Tcl_SetObjResult(interp, message);
        Tcl_SetErrorCode(interp, "APPCOMPILER", "ARGUMENT", "TYPE", NULL);
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, number);
    Tcl_DecrRefCount(number);
    return TCL_OK;
}

/* The compiler supplies the declaration order. Only the public, concrete
 * record path uses this layout; extern and worker boundaries retain their own
 * requirements for unknown fields and handles. */
enum member_kind {MEMBER_TEXT, MEMBER_INT, MEMBER_TEXT_OPTIONAL, MEMBER_INT_OPTIONAL};
static const char *const member_types[] = {"text", "int", "text?", "int?", NULL};
enum {MAX_RECORD_FIELDS = 16};

typedef struct {
    const IntegerTypes *types;
    Tcl_Obj **pairs;
    int kinds[MAX_RECORD_FIELDS];
    Tcl_Size count;
    Tcl_Obj *element;
    Tcl_Obj *path;
    Tcl_Obj *some_tag;
    Tcl_Obj *none_value;
    const Tcl_ObjType *list_type;
} RecordGuard;

static Tcl_Obj *
list_view(Tcl_Obj *value, const Tcl_ObjType *list_type)
{
    Tcl_Obj *view = Tcl_FetchInternalRep(value, list_type) ? value : Tcl_DuplicateObj(value);
    Tcl_IncrRefCount(view);
    return view;
}

static int
record_error(Tcl_Interp *interp, const RecordGuard *guard, Tcl_Size row,
             Tcl_Obj *field, const char *expected)
{
    Tcl_Obj *message = Tcl_NewStringObj("expected ", -1);
    if (expected) {
        Tcl_AppendToObj(message, expected, -1);
    } else {
        if (row < 0) {Tcl_AppendToObj(message, "list<", -1);}
        Tcl_AppendObjToObj(message, guard->element);
        if (row < 0) {Tcl_AppendToObj(message, ">", -1);}
    }
    Tcl_AppendToObj(message, " at ", -1);
    Tcl_AppendObjToObj(message, guard->path);
    if (row >= 0) {Tcl_AppendPrintfToObj(message, ".%lld", (long long)row);}
    if (field) {
        Tcl_AppendToObj(message, ".", 1);
        Tcl_AppendObjToObj(message, field);
    }
    Tcl_SetObjResult(interp, message);
    Tcl_SetErrorCode(interp, "APPCOMPILER", "ARGUMENT", "TYPE", NULL);
    return TCL_ERROR;
}

static int
four_byte_tag(Tcl_Obj *tag, const char *expected)
{
    Tcl_Size length;
    const char *word = Tcl_GetStringFromObj(tag, &length);
    return length == 4 && memcmp(word, expected, 4) == 0;
}

/* The caller receives one owned reference to the number or optional value. */
static Tcl_Obj *
checked_member(const RecordGuard *guard, int kind, Tcl_Obj *member, const char **expected)
{
    *expected = member_types[kind];
    if (kind == MEMBER_INT) {
        return checked_integer(guard->types, member);
    }
    Tcl_Obj *view = list_view(member, guard->list_type);
    Tcl_Size count;
    Tcl_Obj **parts;
    Tcl_Obj *result = NULL;
    if (Tcl_ListObjGetElements(NULL, view, &count, &parts) == TCL_OK) {
        if (count == 1 && four_byte_tag(parts[0], "none")) {
            result = guard->none_value;
            Tcl_IncrRefCount(result);
        } else if (count == 2 && four_byte_tag(parts[0], "some")) {
            Tcl_Obj *elements[] = {guard->some_tag, parts[1]};
            if (kind == MEMBER_INT_OPTIONAL) {
                *expected = "int";
                elements[1] = checked_integer(guard->types, parts[1]);
            }
            if (elements[1]) {
                result = Tcl_NewListObj(2, elements);
                Tcl_IncrRefCount(result);
                if (kind == MEMBER_INT_OPTIONAL) {Tcl_DecrRefCount(elements[1]);}
            }
        }
    }
    Tcl_DecrRefCount(view);
    return result;
}

static int
check_row(Tcl_Interp *interp, const RecordGuard *guard, Tcl_Size index, Tcl_Obj *row)
{
    Tcl_Size size;
    if (Tcl_DictObjSize(NULL, row, &size) != TCL_OK) {
        return record_error(interp, guard, index, NULL, NULL);
    }
    for (Tcl_Size i = 0; i < guard->count; ++i) {
        Tcl_Obj *key = guard->pairs[2*i];
        int kind = guard->kinds[i];
        Tcl_Obj *member;
        if (Tcl_DictObjGet(interp, row, key, &member) != TCL_OK) {return TCL_ERROR;}
        if (!member) {
            if (kind == MEMBER_TEXT_OPTIONAL || kind == MEMBER_INT_OPTIONAL) {continue;}
            return record_error(interp, guard, index, key, member_types[kind]);
        }
        /* Text admission keeps the original member. Discard the cloned
         * dictionary's old spelling just as replacing that member would. */
        if (kind == MEMBER_TEXT) {
            Tcl_InvalidateStringRep(row);
            continue;
        }
        const char *expected;
        Tcl_Obj *checked = checked_member(guard, kind, member, &expected);
        if (!checked) {return record_error(interp, guard, index, key, expected);}
        int code = Tcl_DictObjPut(interp, row, key, checked);
        Tcl_DecrRefCount(checked);
        if (code != TCL_OK) {return code;}
    }
    return TCL_OK;
}

static int
guard_record_list(void *client_data, Tcl_Interp *interp, Tcl_Size objc, Tcl_Obj *const objv[])
{
    if (objc != 5) {
        Tcl_WrongNumArgs(interp, 1, objv, "layout element value path");
        return TCL_ERROR;
    }
    RecordGuard guard = {.types = client_data, .element = objv[2], .path = objv[4],
        .list_type = Tcl_GetObjType("list")};
    Tcl_Obj *layout = list_view(objv[1], guard.list_type);
    Tcl_Size words;
    if (Tcl_ListObjGetElements(interp, layout, &words, &guard.pairs) != TCL_OK ||
        words > 2 * MAX_RECORD_FIELDS || words % 2 != 0) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("invalid compiler record layout", -1));
        Tcl_DecrRefCount(layout);
        return TCL_ERROR;
    }
    guard.count = words / 2;
    Tcl_Obj *dictionary = Tcl_DuplicateObj(layout);
    Tcl_IncrRefCount(dictionary);
    Tcl_Size unique;
    int valid = Tcl_DictObjSize(NULL, dictionary, &unique) == TCL_OK && unique == guard.count;
    Tcl_DecrRefCount(dictionary);
    for (Tcl_Size i = 0; i < guard.count; ++i) {
        /* Layout words are borrowed, including on a direct Tcl call. Do not
         * attach an index cache to the caller's typed objects. */
        Tcl_Size bytes;
        const char *type = Tcl_GetStringFromObj(guard.pairs[2*i + 1], &bytes);
        int kind = 0;
        while (member_types[kind] && (bytes != (Tcl_Size)strlen(member_types[kind]) ||
               memcmp(type, member_types[kind], (size_t)bytes) != 0)) {
            ++kind;
        }
        if (!member_types[kind]) {valid = 0; break;}
        guard.kinds[i] = kind;
    }
    if (!valid) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("invalid compiler record layout", -1));
        Tcl_DecrRefCount(layout);
        return TCL_ERROR;
    }
    Tcl_Obj *input = list_view(objv[3], guard.list_type);
    Tcl_Size count;
    Tcl_Obj **rows;
    int code = TCL_OK;
    if (Tcl_ListObjGetElements(NULL, input, &count, &rows) != TCL_OK) {
        code = record_error(interp, &guard, -1, NULL, NULL);
    } else {
        Tcl_Obj *result = Tcl_NewListObj(0, NULL);
        Tcl_Obj *none_tag = Tcl_NewStringObj("none", 4);
        guard.some_tag = Tcl_NewStringObj("some", 4);
        guard.none_value = Tcl_NewListObj(1, &none_tag);
        Tcl_IncrRefCount(guard.some_tag);
        Tcl_IncrRefCount(guard.none_value);
        Tcl_IncrRefCount(result);
        for (Tcl_Size i = 0; i < count; ++i) {
            Tcl_Obj *row = Tcl_DuplicateObj(rows[i]);
            Tcl_IncrRefCount(row);
            code = check_row(interp, &guard, i, row);
            if (code == TCL_OK) {code = Tcl_ListObjAppendElement(interp, result, row);}
            Tcl_DecrRefCount(row);
            if (code != TCL_OK) {break;}
        }
        if (code == TCL_OK) {Tcl_SetObjResult(interp, result);}
        Tcl_DecrRefCount(result);
        Tcl_DecrRefCount(guard.none_value);
        Tcl_DecrRefCount(guard.some_tag);
    }
    Tcl_DecrRefCount(input);
    Tcl_DecrRefCount(layout);
    return code;
}

static int
guard_integer_list(void *client_data, Tcl_Interp *interp, Tcl_Size objc,
                   Tcl_Obj *const objv[])
{
    if (objc != 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "value path");
        return TCL_ERROR;
    }
    Tcl_Obj *input = objv[1];
    if (!Tcl_FetchInternalRep(input, Tcl_GetObjType("list"))) {
        /* A caller may retain a typed object whose spelling is a Tcl list.
         * Convert a duplicate, preserving that object's own representation. */
        input = Tcl_DuplicateObj(input);
    }
    Tcl_IncrRefCount(input);
    Tcl_Size count;
    Tcl_Obj **items;
    if (Tcl_ListObjGetElements(NULL, input, &count, &items) != TCL_OK) {
        Tcl_DecrRefCount(input);
        return reject(interp, objv[2], -1);
    }
    Tcl_Obj *result = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(result);
    int code = TCL_OK;
    enum { batch_size = 64 };
    Tcl_Obj *batch[batch_size];
    for (Tcl_Size first = 0; first < count && code == TCL_OK;) {
        Tcl_Size size = count - first < batch_size ? count - first : batch_size;
        Tcl_Size filled = 0;
        for (; filled < size; ++filled) {
            batch[filled] = checked_integer(client_data, items[first + filled]);
            if (!batch[filled]) {
                code = reject(interp, objv[2], first + filled);
                break;
            }
        }
        if (code == TCL_OK) {
            code = Tcl_ListObjReplace(interp, result, first, 0, filled, batch);
        }
        /* Each conversion owns a reference, including those before an error. */
        for (Tcl_Size i = 0; i < filled; ++i) {
            Tcl_DecrRefCount(batch[i]);
        }
        first += size;
    }
    if (code == TCL_OK) {
        Tcl_SetObjResult(interp, result);
    }
    Tcl_DecrRefCount(result);
    Tcl_DecrRefCount(input);
    return code;
}

/* Some native strings use a raw zero instead of Tcl's modified UTF-8 C0 80. */
static int
text_contains_nul(const char *bytes, Tcl_Size length)
{
    /* Short map keys are common. Look for both NUL spellings in one pass. */
    if (length <= 24) {
        for (Tcl_Size i = 0; i < length; ++i) {
            if (bytes[i] == 0 || ((unsigned char)bytes[i] == 0xc0 &&
                    i + 1 < length && (unsigned char)bytes[i + 1] == 0x80)) {
                return 1;
            }
        }
        return 0;
    }
    if (memchr(bytes, 0, (size_t)length) != NULL) {
        return 1;
    }
    const char *end = bytes + length;
    while (bytes < end) {
        const char *lead = memchr(bytes, 0xc0, (size_t)(end - bytes));
        if (lead == NULL || lead + 1 == end) {
            break;
        }
        if ((unsigned char)lead[1] == 0x80) {
            return 1;
        }
        bytes = lead + 1;
    }
    return 0;
}

static int
text_has_nul(void *client_data, Tcl_Interp *interp, Tcl_Size objc, Tcl_Obj *const objv[])
{
    (void)client_data;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "text");
        return TCL_ERROR;
    }
    Tcl_Size length;
    const char *bytes = Tcl_GetStringFromObj(objv[1], &length);
    Tcl_SetObjResult(interp, Tcl_NewBooleanObj(text_contains_nul(bytes, length)));
    return TCL_OK;
}

/* Dict keys compare Tcl's byte spelling. Preserve the portable path for
 * embedded NUL, including its strict errors on mixed invalid Unicode. */
static int
map_text_key(void *client_data, Tcl_Interp *interp, Tcl_Size objc,
             Tcl_Obj *const objv[])
{
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "value");
        return TCL_ERROR;
    }
    Tcl_Size length;
    const char *bytes = Tcl_GetStringFromObj(objv[1], &length);
    if (!text_contains_nul(bytes, length)) {
        /* The original may be an opaque native handle. Return a plain key
         * without converting that retained object in place. */
        Tcl_Obj *value = objv[1];
        if (value->typePtr == NULL || Tcl_FetchInternalRep(value, client_data)) {
            Tcl_SetObjResult(interp, value);
        } else {
            Tcl_SetObjResult(interp, Tcl_NewStringObj(bytes, length));
        }
        return TCL_OK;
    }

    Tcl_Encoding utf8 = Tcl_GetEncoding(interp, "utf-8");
    if (utf8 == NULL) {
        return TCL_ERROR;
    }
    Tcl_DString external;
    Tcl_DString normalized;
    int code = Tcl_UtfToExternalDStringEx(interp, utf8, bytes, length,
        TCL_ENCODING_PROFILE_STRICT, &external, NULL);
    if (code == TCL_OK) {
        code = Tcl_ExternalToUtfDStringEx(interp, utf8, Tcl_DStringValue(&external),
            Tcl_DStringLength(&external), TCL_ENCODING_PROFILE_STRICT, &normalized, NULL);
        if (code == TCL_OK) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_DStringValue(&normalized),
                Tcl_DStringLength(&normalized)));
        }
        Tcl_DStringFree(&normalized);
    }
    Tcl_DStringFree(&external);
    Tcl_FreeEncoding(utf8);
    return code == TCL_OK ? TCL_OK : TCL_ERROR;
}

/* Tcl caches character counts on strings. Keep that O(1) path on repeated
 * reads, but never let conversion replace a caller-owned non-string type. */
static int
text_length(void *string_type, Tcl_Interp *interp, Tcl_Size objc,
            Tcl_Obj *const objv[])
{
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "text");
        return TCL_ERROR;
    }
    Tcl_Obj *value = objv[1];
    Tcl_Size length;
    if (value->typePtr == NULL || Tcl_FetchInternalRep(value, string_type)) {
        length = Tcl_GetCharLength(value);
    } else {
        Tcl_Obj *copy = Tcl_DuplicateObj(value);
        Tcl_IncrRefCount(copy);
        length = Tcl_GetCharLength(copy);
        Tcl_DecrRefCount(copy);
    }
    Tcl_SetObjResult(interp, Tcl_NewWideIntObj(length));
    return TCL_OK;
}

/* Canonical fixed point has no sign on zero, gratuitous integer zeroes, or
 * trailing fractional zeroes. Keep arbitrary precision in the text domain. */
static Tcl_Obj *
canonical_decimal_text(const char *text, Tcl_Size length)
{
    const char *end = text + length;
    const char *p = text;
    int negative = p < end && *p == '-';
    if (p < end && (*p == '+' || negative)) {
        ++p;
    }
    const char *whole = p;
    while (p < end && *p >= '0' && *p <= '9') {
        ++p;
    }
    if (p == whole) {
        return NULL;
    }
    const char *point = p;
    if (p < end && *p == '.') {
        const char *fraction = ++p;
        while (p < end && *p >= '0' && *p <= '9') {
            ++p;
        }
        if (p == fraction) {
            return NULL;
        }
    }
    if (p != end) {
        return NULL;
    }
    while (whole + 1 < point && *whole == '0') {
        ++whole;
    }
    if (point != end) {
        while (end > point + 1 && end[-1] == '0') {
            --end;
        }
        if (end == point + 1) {
            end = point;
        }
    }
    if (negative && !(end - whole == 1 && *whole == '0')) {
        if (whole == text + 1) {
            --whole;
        } else {
            Tcl_Obj *result = Tcl_NewStringObj("-", 1);
            Tcl_AppendToObj(result, whole, end - whole);
            return result;
        }
    }
    return Tcl_NewStringObj(whole, end - whole);
}

static int
canonical_decimal(void *client_data, Tcl_Interp *interp, Tcl_Size objc,
                  Tcl_Obj *const objv[])
{
    (void)client_data;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "value");
        return TCL_ERROR;
    }
    Tcl_Obj *value = objv[1];
    Tcl_Obj *copy = NULL;
    if (!Tcl_HasStringRep(value)) {
        /* An opaque caller-owned value can produce decimal text. */
        copy = Tcl_DuplicateObj(value);
        Tcl_IncrRefCount(copy);
        value = copy;
    }
    Tcl_Size length;
    const char *text = Tcl_GetStringFromObj(value, &length);
    Tcl_Obj *result = canonical_decimal_text(text, length);
    if (copy) {
        Tcl_DecrRefCount(copy);
    }
    if (!result) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("expected a fixed-point decimal", -1));
        Tcl_SetErrorCode(interp, "APPCOMPILER", "ARGUMENT", "TYPE", NULL);
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
}


typedef struct {
    int year, month, day, hour, minute, second;
} CivilTime;

/* ASCII decimal fields in the X wire grammar always contain two digits. */
static int time_pair(const char *s) {
    unsigned int tens = (unsigned char)s[0] - (unsigned int)'0';
    unsigned int units = (unsigned char)s[1] - (unsigned int)'0';
    return tens <= 9 && units <= 9 ? (int)(10 * tens + units) : -1;
}

static int
month_length(int year, int month)
{
    static const int days[] = {0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    return days[month] + (month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
}

static int time_fields(const char *s, Tcl_Size n, CivilTime *fields) {
    if (n != 19 && (n < 21 || n > 29 || s[19] != '.')) return 0;
    if (s[4] != '-' || s[7] != '-' || s[10] != 'T' || s[13] != ':' || s[16] != ':') return 0;
    for (Tcl_Size i = 20; i < n; ++i) {
        if (s[i] < '0' || s[i] > '9') return 0;
    }
    int century = time_pair(s), suffix = time_pair(s + 2);
    fields->year = 100 * century + suffix;
    fields->month = time_pair(s + 5);
    fields->day = time_pair(s + 8);
    fields->hour = time_pair(s + 11);
    fields->minute = time_pair(s + 14);
    fields->second = time_pair(s + 17);
    if (century < 0 || suffix < 0 || fields->year == 0 || fields->month < 1 ||
            fields->month > 12 || fields->day < 1 || fields->hour < 0 || fields->hour > 23 ||
            fields->minute < 0 || fields->minute > 59 || fields->second < 0 || fields->second > 59) {
        return 0;
    }
    return fields->day <= month_length(fields->year, fields->month);
}

/* Return an empty list for any unrecognized spelling or opaque value.
 * The corresponding Tcl routine remains authoritative for those calls. */
static int time_probe(void *context, Tcl_Interp *interp, Tcl_Size objc, Tcl_Obj *const objv[]) {
    (void)context;
    if (objc != 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "mode value");
        return TCL_ERROR;
    }
    if (!Tcl_HasStringRep(objv[1]) || !Tcl_HasStringRep(objv[2])) return TCL_OK;
    Tcl_Size length, mode_length;
    const char *mode = Tcl_GetStringFromObj(objv[1], &mode_length);
    const char *s = Tcl_GetStringFromObj(objv[2], &length);
    int parts = mode_length == 5 && !memcmp(mode, "parts", 5);
    if (!parts) {
        if (mode_length == 7 && !memcmp(mode, "instant", 7)) {
            if (length != 30 || s[length - 1] != 'Z') return TCL_OK;
            --length;
        } else if (mode_length == 14 && !memcmp(mode, "local_datetime", 14)) {
            if (length > 19 && s[length - 1] == '0') return TCL_OK;
        } else {
            return TCL_OK;
        }
    }
    CivilTime fields;
    if (!time_fields(s, length, &fields)) return TCL_OK;
    if (parts) {
        Tcl_Size end = length;
        while (end > 20 && s[end - 1] == '0') --end;
        Tcl_Obj *result[] = {
            Tcl_NewIntObj(fields.year), Tcl_NewIntObj(fields.month), Tcl_NewIntObj(fields.day),
            Tcl_NewIntObj(fields.hour), Tcl_NewIntObj(fields.minute), Tcl_NewIntObj(fields.second),
            end > 20 ? Tcl_NewStringObj(s + 20, end - 20) : Tcl_NewObj()
        };
        Tcl_SetObjResult(interp, Tcl_NewListObj(7, result));
    } else {
        Tcl_SetObjResult(interp, Tcl_NewBooleanObj(1));
    }
    return TCL_OK;
}

static void
put_digit_pair(char *out, int number)
{
    out[0] = (char)('0' + number / 10);
    out[1] = (char)('0' + number % 10);
}

/* A miss leaves normalization and its source diagnostic to the existing Tcl
 * parser. Only inspect materialized bytes. No foreign stringifier is called. */
static int
normalize_instant(void *context, Tcl_Interp *interp, Tcl_Size objc, Tcl_Obj *const objv[])
{
    (void)context;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "value");
        return TCL_ERROR;
    }
    if (!Tcl_HasStringRep(objv[1])) return TCL_OK;
    Tcl_Size length;
    const char *s = Tcl_GetStringFromObj(objv[1], &length);
    if (length < 20 || length > 35) return TCL_OK;
    Tcl_Size local = length - 1;
    int offset = 0;
    if (s[local] != 'Z') {
        local = length - 6;
        const char *zone = s + local;
        if ((zone[0] != '+' && zone[0] != '-') || zone[3] != ':') return TCL_OK;
        int hours = time_pair(zone + 1);
        int minutes = time_pair(zone + 4);
        if (hours < 0 || minutes < 0 || minutes > 59) return TCL_OK;
        offset = 60 * hours + minutes;
        if (offset > 840 || (offset == 0 && zone[0] == '-')) return TCL_OK;
        if (zone[0] == '-') offset = -offset;
    }
    CivilTime f;
    if (!time_fields(s, local, &f)) return TCL_OK;
    char result[30];
    memcpy(result, s, 19);
    if (offset != 0) {
        int utc = f.hour * 60 + f.minute - offset;
        if (utc < 0) {
            utc += 1440;
            if (--f.day == 0) {
                if (--f.month == 0) {
                    f.month = 12;
                    if (--f.year == 0) return TCL_OK;
                }
                f.day = month_length(f.year, f.month);
            }
        } else if (utc >= 1440) {
            utc -= 1440;
            if (++f.day > month_length(f.year, f.month)) {
                f.day = 1;
                if (++f.month == 13) {
                    f.month = 1;
                    if (++f.year == 10000) return TCL_OK;
                }
            }
        }
        put_digit_pair(result, f.year / 100);
        put_digit_pair(result + 2, f.year % 100);
        put_digit_pair(result + 5, f.month);
        put_digit_pair(result + 8, f.day);
        put_digit_pair(result + 11, utc / 60);
        put_digit_pair(result + 14, utc % 60);
    }
    result[19] = '.';
    memset(result + 20, '0', 9);
    if (local > 20) memcpy(result + 20, s + 20, (size_t)(local - 20));
    result[29] = 'Z';
    /* The Tcl offset formatter appends Z to a built string. Preserve that
     * representation for a Tcl extension borrowing the returned timestamp. */
    Tcl_Obj *normalized;
    if (offset != 0) {
        normalized = Tcl_NewStringObj(result, 29);
        Tcl_AppendToObj(normalized, "Z", 1);
    } else {
        normalized = Tcl_NewStringObj(result, sizeof(result));
    }
    Tcl_SetObjResult(interp, normalized);
    return TCL_OK;
}

enum { DecimalOperandBytes = 64 };
static const int64_t decimal_limit = INT64_C(999999999999999999);

typedef struct {
    int64_t coefficient;
    int scale;
} DecimalOperand;

/* A miss leaves both arguments untouched. Tcl's arbitrary-precision path
 * handles whole numbers, opaque objects, and every larger spelling. */
static int
decimal_fraction(Tcl_Obj *value, const Tcl_ObjType *string_type, DecimalOperand *result)
{
    if (value->bytes == NULL || value->length < 3 || value->length > DecimalOperandBytes ||
            (value->typePtr != NULL && value->typePtr != string_type)) return 0;
    const char *p = value->bytes, *end = p + value->length;
    int negative = *p == '-';
    if (negative) ++p;
    if (*p < '0' || *p > '9' || (*p == '0' && p[1] != '.')) return 0;
    int fraction = 0, scale = 0;
    int64_t coefficient = 0;
    for (; p < end; ++p) {
        if (*p == '.' && !fraction) {
            fraction = 1;
        } else {
            if (*p < '0' || *p > '9' || coefficient > decimal_limit / 10) return 0;
            coefficient = coefficient * 10 + (*p - '0');
            scale += fraction;
        }
    }
    if (scale == 0 || end[-1] == '0') return 0;
    result->coefficient = negative ? -coefficient : coefficient;
    result->scale = scale;
    return 1;
}

static int64_t
decimal_magnitude(int64_t value)
{
    return value < 0 ? -value : value;
}

static int
decimal_align(DecimalOperand *value, int scale)
{
    while (value->scale < scale) {
        if (decimal_magnitude(value->coefficient) > decimal_limit / 10) return 0;
        value->coefficient *= 10;
        ++value->scale;
    }
    return 1;
}

/* Inputs have at most DecimalOperandBytes fractional places each. The sum
 * of two bounded coefficients fits in int64_t even with opposite signs. */
static Tcl_Obj *
decimal_result(int64_t coefficient, int scale)
{
    char buffer[2 * DecimalOperandBytes + 4];
    char *end = buffer + sizeof(buffer), *p = end;
    int64_t n = decimal_magnitude(coefficient);
    int final_digit = (int)(n % 10);
    while (scale && n % 10 == 0) {
        n /= 10;
        --scale;
    }
    for (int i = 0; i < scale; ++i) {
        *--p = (char)('0' + n % 10);
        n /= 10;
    }
    if (scale) *--p = '.';
    /* fromParts constructs negative values and untrimmed subunit values by
     * concatenation. Keep that string representation for Tcl extensions. */
    int concatenated = coefficient < 0 || (n == 0 && final_digit != 0);
    do {
        *--p = (char)('0' + n % 10);
        n /= 10;
    } while (n);
    if (coefficient < 0) *--p = '-';
    if (concatenated) {
        Tcl_Obj *value = Tcl_NewStringObj(p, (Tcl_Size)(end - p - 1));
        Tcl_AppendToObj(value, end - 1, 1);
        return value;
    }
    return Tcl_NewStringObj(p, (Tcl_Size)(end - p));
}

static int
try_decimal_arithmetic(void *string_type, Tcl_Interp *interp, Tcl_Size objc, Tcl_Obj *const objv[])
{
    if (objc != 4) {
        Tcl_WrongNumArgs(interp, 1, objv, "operator left right");
        return TCL_ERROR;
    }
    Tcl_Obj *op = objv[1];
    DecimalOperand a, b;
    if (op->bytes == NULL || op->length != 1 ||
            !decimal_fraction(objv[2], string_type, &a) ||
            !decimal_fraction(objv[3], string_type, &b)) return TCL_OK;
    int64_t result;
    int scale;
    if (op->bytes[0] == '*') {
        if (decimal_magnitude(b.coefficient) > decimal_limit / decimal_magnitude(a.coefficient)) return TCL_OK;
        result = a.coefficient * b.coefficient;
        scale = a.scale + b.scale;
    } else if (op->bytes[0] == '+' || op->bytes[0] == '-') {
        scale = a.scale > b.scale ? a.scale : b.scale;
        if (!decimal_align(&a, scale) || !decimal_align(&b, scale)) return TCL_OK;
        result = op->bytes[0] == '+' ? a.coefficient + b.coefficient : a.coefficient - b.coefficient;
    } else {
        return TCL_OK;
    }
    if (result) {
        /* canonicalParts caches string information on plain fraction words. */
        if (objv[2]->typePtr == NULL) (void)Tcl_GetCharLength(objv[2]);
        if (objv[3]->typePtr == NULL) (void)Tcl_GetCharLength(objv[3]);
        Tcl_SetObjResult(interp, decimal_result(result, scale));
    }
    return TCL_OK;
}

static int
register_text_commands(Tcl_Interp *interp)
{
    Tcl_Namespace *ns = Tcl_FindNamespace(interp, "::machteld::x", NULL, TCL_GLOBAL_ONLY);
    if (!ns) {
        ns = Tcl_CreateNamespace(interp, "::machteld::x", NULL, NULL);
    }
    if (!ns || !Tcl_CreateObjCommand2(interp, "::machteld::x::mapTextKey", map_text_key,
            (void *)Tcl_GetObjType("string"), NULL) ||
            Tcl_Export(interp, ns, "mapTextKey", 0) != TCL_OK ||
            !Tcl_CreateObjCommand2(interp, "::machteld::x::textHasNul", text_has_nul, NULL, NULL) ||
            Tcl_Export(interp, ns, "textHasNul", 0) != TCL_OK ||
            !Tcl_CreateObjCommand2(interp, "::machteld::x::textLength", text_length,
                (void *)Tcl_GetObjType("string"), NULL) ||
            Tcl_Export(interp, ns, "textLength", 0) != TCL_OK ||
            !Tcl_CreateObjCommand2(interp, "::machteld::x::canonicalDecimal", canonical_decimal,
                NULL, NULL) ||
            Tcl_Export(interp, ns, "canonicalDecimal", 0) != TCL_OK ||
            !Tcl_CreateObjCommand2(interp, "::machteld::x::tryDecimalArithmetic", try_decimal_arithmetic,
                (void *)Tcl_GetObjType("string"), NULL) ||
            Tcl_Export(interp, ns, "tryDecimalArithmetic", 0) != TCL_OK ||
            !Tcl_CreateObjCommand2(interp, "::machteld::x::civilTime", time_probe, NULL, NULL) ||
            Tcl_Export(interp, ns, "civilTime", 0) != TCL_OK ||
            !Tcl_CreateObjCommand2(interp, "::machteld::x::normalizeInstant", normalize_instant, NULL, NULL) ||
            Tcl_Export(interp, ns, "normalizeInstant", 0) != TCL_OK) {
        return TCL_ERROR;
    }
    return TCL_OK;
}

#ifdef MACHTELD_UCRT_BINARY64_PRINT
typedef struct {
    _locale_t locale;
    const Tcl_ObjType *double_type;
} Binary64Print;

/* The public UCRT printf wrappers inherit per-module rounding options.
 * Supply both the standard tie rule and the decimal locale per call. */
static int
print_c_locale(char *buffer, size_t size, _locale_t locale, const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    /* UCRT may set the inexact and denormal status flags. All traps are
     * already masked on this path; restore the caller's original flags. */
    unsigned csr = _mm_getcsr();
    int length = __stdio_common_vsprintf(_CRT_INTERNAL_PRINTF_STANDARD_ROUNDING |
        _CRT_INTERNAL_PRINTF_STANDARD_SNPRINTF_BEHAVIOR, buffer, size, format, locale, arguments);
    _mm_setcsr(csr);
    va_end(arguments);
    return length;
}

static int
binary64_print_controls(void)
{
    /* Nearest, gradual underflow, masked exceptions. Never change thread controls. */
    return (_mm_getcsr() & 0xffc0u) == 0x1f80u && fegetround() == FE_TONEAREST;
}

static int
binary64_print(void *data, Tcl_Interp *interp, Tcl_Size objc, Tcl_Obj *const objv[])
{
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "number");
        return TCL_ERROR;
    }
    Binary64Print *settings = data;
    Tcl_ObjInternalRep *rep = Tcl_FetchInternalRep(objv[1], settings->double_type);
    if (!rep || !binary64_print_controls()) {return TCL_OK;}
    uint64_t bits;
    memcpy(&bits, &rep->doubleValue, sizeof(bits));
    if ((bits & UINT64_C(0x7ff0000000000000)) == UINT64_C(0x7ff0000000000000)) {
        return TCL_OK;
    }
    char text[32];
    int length = print_c_locale(text, sizeof(text), settings->locale, "%.17g", rep->doubleValue);
    if (length > 0 && (size_t)length < sizeof(text)) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(text, length));
    }
    return TCL_OK;
}

static void
free_binary64_print(void *data)
{
    Binary64Print *settings = data;
    _free_locale(settings->locale);
    Tcl_Free(settings);
}

static int
register_binary64_print(Tcl_Interp *interp)
{
    const Tcl_ObjType *double_type = Tcl_GetObjType("double");
    if (!double_type || !binary64_print_controls()) {return TCL_OK;}
    _locale_t locale = _create_locale(LC_NUMERIC, "C");
    if (!locale) {return TCL_OK;}
    /* Older UCRTs ignore the standard-rounding flag. 2^-25 is halfway and
     * must round its 17th digit down to even, including in scientific form. */
    char probe[32];
    const char expected[] = "2.9802322387695312e-08";
    if (print_c_locale(probe, sizeof(probe), locale, "%.17g", 0x1p-25) != (int)(sizeof(expected) - 1) ||
            strcmp(probe, expected) != 0) {
        _free_locale(locale);
        return TCL_OK;
    }
    Binary64Print *settings = (Binary64Print *)Tcl_Alloc(sizeof(*settings));
    settings->locale = locale;
    settings->double_type = double_type;
    Tcl_Namespace *ns = Tcl_FindNamespace(interp, "::machteld::x", NULL, TCL_GLOBAL_ONLY);
    if (!Tcl_CreateObjCommand2(interp, "::machteld::x::binary64Print", binary64_print,
            settings, free_binary64_print)) {
        free_binary64_print(settings);
        return TCL_ERROR;
    }
    return Tcl_Export(interp, ns, "binary64Print", 0);
}
#endif

int
MachteldCompilerGuard_Init(Tcl_Interp *interp)
{
    if (register_text_commands(interp) != TCL_OK || MachteldBinary64Operators_Init(interp) != TCL_OK) {
        return TCL_ERROR;
    }
#ifdef MACHTELD_UCRT_BINARY64_PRINT
    if (register_binary64_print(interp) != TCL_OK) {return TCL_ERROR;}
#endif
    IntegerTypes *types = integer_types(interp);
    if (!types || !Tcl_CreateObjCommand2(interp, "::machteld::GuardRecordList",
            guard_record_list, types, NULL)) {
        return TCL_ERROR;
    }
    if (!Tcl_CreateObjCommand2(interp, "::machteld::GuardIntegerList", guard_integer_list, types, NULL) ||
            !Tcl_CreateObjCommand2(interp, "::machteld::x::guardInteger", guard_integer, types, NULL)) {
        return TCL_ERROR;
    }
    return Tcl_Export(interp, Tcl_FindNamespace(interp, "::machteld::x", NULL, TCL_GLOBAL_ONLY), "guardInteger", 0);
}
