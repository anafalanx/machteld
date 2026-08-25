/*
 * json.c -- ::machteld::json encode|decode. The READER stands on the pinned
 * yyjson core (plan-machteld-015); the EMITTER is machteld's own, unchanged --
 * its byte choices (escape table, lowercase \u%04x, the postcode rule) are
 * contract behavior no vendored writer is asked to reproduce. Checked against
 * the JSONTestSuite corpus kept under test/.
 *
 * THE MAPPING, which is the hard part rather than the parsing. Tcl has no type
 * tags, so JSON's types do not survive a plain round trip unaided:
 *
 *   decode:  null -> ""      true -> 1      false -> 0
 *            number -> its LITERAL TEXT, so nothing is lost to a double and
 *                      Tcl 9's bignums keep huge integers exact
 *            string -> the string;  array -> a list;  object -> a dict
 *
 *   encode:  a value is emitted as a NUMBER only if it is already a valid JSON
 *            number literal, exactly as written. Everything else is a string.
 *
 * That last rule is the postcode rule. `string is integer` would call "01234"
 * a number and emit it as 1234 -- the exact silent corruption a type system
 * exists to prevent. A leading zero is not a valid JSON number, so "01234"
 * stays a quoted string and the postcode survives. The cost, stated plainly:
 * a string that happens to look like a number ("1.5") encodes as a number, and
 * booleans and nulls do not round-trip in PLAIN mode. Both are documented in
 * the contract; the typed mode exists for programs that need more.
 *
 * One ruled tightening against the old hand parser (plan-machteld-015, the J1
 * table): an unpaired \uD800-class surrogate escape used to decode to U+FFFD;
 * it is now a parse error. machteld does not manufacture replacement
 * characters from broken input, the wire never legally carries lone
 * surrogates, and the affected JSONTestSuite cases are implementation-defined
 * by the suite's own charter.
 */
#undef USE_TCL_STUBS
#include "machteld.h"
#include <string.h>
#include <stdlib.h>
#include "yyjson.h"

/* Nesting cap. JSONTestSuite deliberately includes 100000-deep input; yyjson
 * parses iteratively so nothing can smash a stack, but the CONTRACT caps the
 * depth of what a machteld program receives ("depth is capped, not crashed"),
 * and the doc-to-Tcl walk below is recursive besides. 512 is far past any real
 * document and leaves the i_structure_500_nested_arrays case
 * (implementation-defined) decoding successfully, exactly as before. */
#define JSON_MAX_DEPTH 512

/* Walk one yyjson value into the plain-mode Tcl mapping. NUMBER_AS_RAW makes
 * every number arrive as its LITERAL TEXT, which is the old parser's exact
 * behavior: nothing is lost to a double, Tcl 9's bignums keep 40-digit
 * integers, re-encoding is byte-identical. Duplicate object keys are walked
 * in wire order into Tcl_DictObjPut, so the last one wins -- also exactly as
 * before. Returns NULL with *depthErr set on a depth breach. */
static Tcl_Obj *yy_to_tcl(yyjson_val *v, int depth, int *depthErr) {
    if (depth >= JSON_MAX_DEPTH) {
        *depthErr = 1;
        return NULL;
    }
    switch (yyjson_get_type(v)) {
        case YYJSON_TYPE_NULL:
            return Tcl_NewObj();
        case YYJSON_TYPE_BOOL:
            return Tcl_NewIntObj(yyjson_get_bool(v) ? 1 : 0);
        case YYJSON_TYPE_RAW:
            return Tcl_NewStringObj(yyjson_get_raw(v),
                                    (Tcl_Size)yyjson_get_len(v));
        case YYJSON_TYPE_STR:
            return Tcl_NewStringObj(yyjson_get_str(v),
                                    (Tcl_Size)yyjson_get_len(v));
        case YYJSON_TYPE_ARR: {
            Tcl_Obj *l = Tcl_NewListObj(0, NULL);
            yyjson_arr_iter it;
            yyjson_arr_iter_init(v, &it);
            yyjson_val *el;
            while ((el = yyjson_arr_iter_next(&it)) != NULL) {
                Tcl_Obj *o = yy_to_tcl(el, depth + 1, depthErr);
                if (o == NULL) { Tcl_DecrRefCount(l); return NULL; }
                Tcl_ListObjAppendElement(NULL, l, o);
            }
            return l;
        }
        case YYJSON_TYPE_OBJ: {
            Tcl_Obj *d = Tcl_NewDictObj();
            yyjson_obj_iter it;
            yyjson_obj_iter_init(v, &it);
            yyjson_val *k;
            while ((k = yyjson_obj_iter_next(&it)) != NULL) {
                yyjson_val *val = yyjson_obj_iter_get_val(k);
                Tcl_Obj *ko = Tcl_NewStringObj(yyjson_get_str(k),
                                               (Tcl_Size)yyjson_get_len(k));
                Tcl_Obj *vo = yy_to_tcl(val, depth + 1, depthErr);
                if (vo == NULL) {
                    Tcl_DecrRefCount(ko);
                    Tcl_DecrRefCount(d);
                    return NULL;
                }
                Tcl_DictObjPut(NULL, d, ko, vo);
            }
            return d;
        }
        default:
            *depthErr = 0;
            return NULL;                 /* unreachable under our read flags */
    }
}

/* ---- encode ------------------------------------------------------------- */

/* Is this string EXACTLY a JSON number literal? Deliberately not `string is
 * double`, which accepts "0x10", " 1 ", "1_000", "Inf" and -- the one that
 * matters -- "01234". A leading zero is not a JSON number, so a postcode stays
 * a quoted string instead of silently becoming 1234. */
static int json_is_number_literal(const char *s, Tcl_Size n) {
    Tcl_Size i = 0;
    if (n == 0) return 0;
    if (s[i] == '-') i++;
    if (i >= n) return 0;
    if (s[i] == '0') { i++; }
    else if (s[i] >= '1' && s[i] <= '9') { while (i < n && s[i] >= '0' && s[i] <= '9') i++; }
    else return 0;
    if (i < n && s[i] == '.') {
        i++;
        if (i >= n || s[i] < '0' || s[i] > '9') return 0;
        while (i < n && s[i] >= '0' && s[i] <= '9') i++;
    }
    if (i < n && (s[i] == 'e' || s[i] == 'E')) {
        i++;
        if (i < n && (s[i] == '+' || s[i] == '-')) i++;
        if (i >= n || s[i] < '0' || s[i] > '9') return 0;
        while (i < n && s[i] >= '0' && s[i] <= '9') i++;
    }
    return i == n;
}

static void json_quote(Tcl_DString *out, const char *s, Tcl_Size n) {
    Tcl_DStringAppend(out, "\"", 1);
    for (Tcl_Size i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
            case '"':  Tcl_DStringAppend(out, "\\\"", 2); break;
            case '\\': Tcl_DStringAppend(out, "\\\\", 2); break;
            case '\b': Tcl_DStringAppend(out, "\\b", 2);  break;
            case '\f': Tcl_DStringAppend(out, "\\f", 2);  break;
            case '\n': Tcl_DStringAppend(out, "\\n", 2);  break;
            case '\r': Tcl_DStringAppend(out, "\\r", 2);  break;
            case '\t': Tcl_DStringAppend(out, "\\t", 2);  break;
            default:
                if (c < 0x20) {
                    char b[8];
                    snprintf(b, sizeof b, "\\u%04x", c);
                    Tcl_DStringAppend(out, b, 6);
                } else {
                    Tcl_DStringAppend(out, (const char *)&s[i], 1);
                }
        }
    }
    Tcl_DStringAppend(out, "\"", 1);
}

static int json_emit(Tcl_Interp *interp, Tcl_Obj *v, Tcl_DString *out, int as_dict, int depth);

static int json_emit_list(Tcl_Interp *interp, Tcl_Obj *v, Tcl_DString *out, int depth) {
    Tcl_Size n;
    Tcl_Obj **el;
    if (Tcl_ListObjGetElements(interp, v, &n, &el) != TCL_OK) return TCL_ERROR;
    Tcl_DStringAppend(out, "[", 1);
    for (Tcl_Size i = 0; i < n; i++) {
        if (i) Tcl_DStringAppend(out, ",", 1);
        if (json_emit(interp, el[i], out, 0, depth + 1) != TCL_OK) return TCL_ERROR;
    }
    Tcl_DStringAppend(out, "]", 1);
    return TCL_OK;
}

static int json_emit_dict(Tcl_Interp *interp, Tcl_Obj *v, Tcl_DString *out, int depth) {
    Tcl_DictSearch s;
    Tcl_Obj *k, *val;
    int done;
    if (Tcl_DictObjFirst(interp, v, &s, &k, &val, &done) != TCL_OK) return TCL_ERROR;
    Tcl_DStringAppend(out, "{", 1);
    int first = 1;
    for (; !done; Tcl_DictObjNext(&s, &k, &val, &done)) {
        if (!first) Tcl_DStringAppend(out, ",", 1);
        first = 0;
        Tcl_Size kl;
        const char *ks = Tcl_GetStringFromObj(k, &kl);
        json_quote(out, ks, kl);       /* a JSON key is always a string */
        Tcl_DStringAppend(out, ":", 1);
        if (json_emit(interp, val, out, 0, depth + 1) != TCL_OK) {
            Tcl_DictObjDone(&s);
            return TCL_ERROR;
        }
    }
    Tcl_DictObjDone(&s);
    Tcl_DStringAppend(out, "}", 1);
    return TCL_OK;
}

/* Structure comes from what the VALUE IS, never from what its text looks like.
 *
 * Asking "does this string parse as a list?" is the trap: in Tcl every string
 * with a space in it parses as a list, so `hello world` would encode as
 * ["hello","world"] and any sentence in a document would silently become an
 * array. That is the postcode rule again, one level up -- and it is worse,
 * because it corrupts ordinary prose rather than an unusual number.
 *
 * So the decision is the object's own current representation, which Tcl already
 * tracks: a dict is an object, a list is an array, anything else is a scalar.
 * `json decode` builds real dict and list objects, so a document round-trips
 * exactly; `dict create` and `list` do the same for a document built by hand.
 * -dict and -list force the reading when a value has no type of its own.
 *
 * The honest caveat, documented in the contract: Tcl converts representations
 * on demand, so calling `llength` on a plain string can leave it a list object
 * and change how it encodes here. If it matters, say -dict or -list.
 */
static int json_emit(Tcl_Interp *interp, Tcl_Obj *v, Tcl_DString *out, int as_dict, int depth) {
    if (depth >= JSON_MAX_DEPTH) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("value is too deeply nested", -1));
        Tcl_SetErrorCode(interp, "MACHTELD", "JSON", "depth", (char *)NULL);
        return TCL_ERROR;
    }
    if (as_dict) return json_emit_dict(interp, v, out, depth);

    static const Tcl_ObjType *dictType = NULL, *listType = NULL;
    if (dictType == NULL) dictType = Tcl_GetObjType("dict");
    if (listType == NULL) listType = Tcl_GetObjType("list");

    const Tcl_ObjType *t = v->typePtr;
    if (t != NULL && t == dictType) return json_emit_dict(interp, v, out, depth);
    if (t != NULL && t == listType) return json_emit_list(interp, v, out, depth);

    Tcl_Size n;
    const char *s = Tcl_GetStringFromObj(v, &n);
    if (json_is_number_literal(s, n)) { Tcl_DStringAppend(out, s, n); return TCL_OK; }
    json_quote(out, s, n);
    return TCL_OK;
}

/* ---- the verb ----------------------------------------------------------- */

static int JsonCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    static const char *const subs[] = { "decode", "encode", NULL };
    enum { DECODE, ENCODE };
    int idx;
    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "subcommand ?arg ...?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", TCL_EXACT, &idx) != TCL_OK) return TCL_ERROR;

    if (idx == DECODE) {
        if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "text"); return TCL_ERROR; }
        Tcl_Size n;
        const char *s = Tcl_GetStringFromObj(objv[2], &n);
        yyjson_read_err rerr;
        yyjson_doc *doc = yyjson_read_opts((char *)s, (size_t)n,
            YYJSON_READ_NUMBER_AS_RAW, NULL, &rerr);
        if (doc == NULL) {
            char msg[192];
            snprintf(msg, sizeof msg, "%s (byte %zu)",
                     rerr.msg ? rerr.msg : "invalid JSON", rerr.pos);
            Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
            Tcl_SetErrorCode(interp, "MACHTELD", "JSON", "parse", (char *)NULL);
            return TCL_ERROR;
        }
        int depthErr = 0;
        Tcl_Obj *v = yy_to_tcl(yyjson_doc_get_root(doc), 0, &depthErr);
        yyjson_doc_free(doc);
        if (v == NULL) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj(
                depthErr ? "too deeply nested" : "invalid JSON", -1));
            Tcl_SetErrorCode(interp, "MACHTELD", "JSON",
                depthErr ? "depth" : "parse", (char *)NULL);
            return TCL_ERROR;
        }
        Tcl_SetObjResult(interp, v);
        return TCL_OK;
    }

    /* Keep ENCODE explicit rather than relying on fall-through; the two public
     * branches then remain independently readable and testable. */
    if (idx == ENCODE) {
    int as_dict = 0, as_list = 0, options = 1;
    Tcl_Obj *val = NULL;
    for (int i = 2; i < objc; i++) {
        const char *a = Tcl_GetString(objv[i]);
        if (options && strcmp(a, "--") == 0) { options = 0; continue; }
        if (options && strcmp(a, "-dict") == 0) { as_dict = 1; continue; }
        if (options && strcmp(a, "-list") == 0) { as_list = 1; continue; }
        if (val != NULL) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("unknown option", -1));
            Tcl_SetErrorCode(interp, "MACHTELD", "JSON", "usage", (char *)NULL);
            return TCL_ERROR;
        }
        val = objv[i];
    }
    if (val == NULL) { Tcl_WrongNumArgs(interp, 2, objv, "?-dict|-list? value"); return TCL_ERROR; }
    if (as_dict && as_list) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("-dict and -list are exclusive", -1));
        Tcl_SetErrorCode(interp, "MACHTELD", "JSON", "usage", (char *)NULL);
        return TCL_ERROR;
    }

    Tcl_DString out;
    Tcl_DStringInit(&out);
    if (as_list) {
        if (json_emit_list(interp, val, &out, 0) != TCL_OK) { Tcl_DStringFree(&out); return TCL_ERROR; }
        Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_DStringValue(&out), Tcl_DStringLength(&out)));
        Tcl_DStringFree(&out);
        return TCL_OK;
    }
    if (json_emit(interp, val, &out, as_dict, 0) != TCL_OK) {
        Tcl_DStringFree(&out);
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_DStringValue(&out), Tcl_DStringLength(&out)));
    Tcl_DStringFree(&out);
    return TCL_OK;
    }
    return TCL_OK;   /* unreachable: Tcl_GetIndexFromObj admits only the two */
}

int Machteldjson_Init(Tcl_Interp *interp) {
    if (Tcl_CreateObjCommand(interp, "::machteld::json", JsonCmd, NULL, NULL) == NULL) {
        return TCL_ERROR;
    }
    if (Tcl_PkgProvide(interp, "machteld::json", MACHTELD_VERSION) != TCL_OK) {
        Tcl_DeleteCommand(interp, "::machteld::json");
        return TCL_ERROR;
    }
    return TCL_OK;
}
