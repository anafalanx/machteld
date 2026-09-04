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

/* ---- typed values (plan-machteld-015) -----------------------------------
 *
 * A typed value is an opaque Tcl_Obj carrying real JSON identity. Containers
 * are DOCUMENT-BACKED: one constructor pass builds an immutable subtree in a
 * yyjson document, so inside a typed container there are no per-leaf Tcl_Objs
 * left to shimmer - the only shimmerable object is the handle itself. The
 * shimmer law, enforced where it is decidable: constructors accept typed
 * values and nested plain dict/list CONTAINERS (recursed), and refuse plain
 * SCALARS by name - a shimmered typed boolean has become the plain string
 * "true", indistinguishable from one that was never typed, so silence here
 * would readmit the exact corruption class this mode exists to kill.
 *
 * The wrapper is refcounted and holds either an immutable document (from
 * `json decode -typed`) or a mutable one (from the constructors); a typed
 * Tcl_Obj's intrep is {wrapper, node}. A typed value's STRING REP is its
 * JSON text - honest for debugging, and a value rebuilt from that text is
 * plain by design (text carries no type authority). */

typedef struct {
    int refCount;
    yyjson_doc     *idoc;            /* exactly one of idoc/mdoc is set */
    yyjson_mut_doc *mdoc;
} JsonDocWrap;

static void JsonTypeFree(Tcl_Obj *o);
static void JsonTypeDup(Tcl_Obj *src, Tcl_Obj *dst);
static void JsonTypeString(Tcl_Obj *o);

static const Tcl_ObjType jsonValueType = {
    "machteldJson",
    JsonTypeFree,
    JsonTypeDup,
    JsonTypeString,
    NULL,
    TCL_OBJTYPE_V0
};

#define JWRAP(o)  ((JsonDocWrap *)((o)->internalRep.twoPtrValue.ptr1))
#define JNODE(o)  ((o)->internalRep.twoPtrValue.ptr2)

static void JsonWrapRelease(JsonDocWrap *w) {
    if (w != NULL && --w->refCount == 0) {
        if (w->idoc != NULL) yyjson_doc_free(w->idoc);
        if (w->mdoc != NULL) yyjson_mut_doc_free(w->mdoc);
        Tcl_Free(w);
    }
}

static void JsonTypeFree(Tcl_Obj *o) {
    JsonWrapRelease(JWRAP(o));
    o->typePtr = NULL;
}

static void JsonTypeDup(Tcl_Obj *src, Tcl_Obj *dst) {
    JsonDocWrap *w = JWRAP(src);
    w->refCount++;
    dst->internalRep.twoPtrValue.ptr1 = w;
    dst->internalRep.twoPtrValue.ptr2 = JNODE(src);
    dst->typePtr = &jsonValueType;
}

/* Write one node (immutable or mutable, per the wrapper) as JSON text.
 * The typed writer is yyjson's own; its byte choices are NEW contract
 * surface with no parity debt to the plain emitter. */
static char *JsonNodeWrite(Tcl_Obj *o, size_t *lenOut) {
    JsonDocWrap *w = JWRAP(o);
    if (w->idoc != NULL) {
        return yyjson_val_write((yyjson_val *)JNODE(o), 0, lenOut);
    }
    return yyjson_mut_val_write((yyjson_mut_val *)JNODE(o), 0, lenOut);
}

static void JsonTypeString(Tcl_Obj *o) {
    size_t n = 0;
    char *s = JsonNodeWrite(o, &n);
    if (s == NULL) { s = strdup("null"); n = 4; }
    o->bytes = Tcl_Alloc((Tcl_Size)n + 1);
    memcpy(o->bytes, s, n);
    o->bytes[n] = '\0';
    o->length = (Tcl_Size)n;
    free(s);
}

static Tcl_Obj *JsonNewTyped(JsonDocWrap *w, void *node) {
    Tcl_Obj *o = Tcl_NewObj();
    Tcl_InvalidateStringRep(o);
    w->refCount++;
    o->internalRep.twoPtrValue.ptr1 = w;
    o->internalRep.twoPtrValue.ptr2 = node;
    o->typePtr = &jsonValueType;
    return o;
}

static int JsonIsTyped(Tcl_Obj *o) {
    return o->typePtr == &jsonValueType;
}

/* Build a mutable copy of a typed value's node inside doc (cross-document
 * composition: a leaf decoded from the wire can enter a constructed tree). */
static yyjson_mut_val *JsonNodeToMut(yyjson_mut_doc *doc, Tcl_Obj *o) {
    JsonDocWrap *w = JWRAP(o);
    if (w->idoc != NULL) {
        return yyjson_val_mut_copy(doc, (yyjson_val *)JNODE(o));
    }
    return yyjson_mut_val_mut_copy(doc, (yyjson_mut_val *)JNODE(o));
}

/* The constructor walk: a Tcl value into a mutable node. Typed values copy;
 * dicts and lists recurse; a plain SCALAR refuses (the shimmer law's
 * decidable edge). The dict/list decision mirrors plain encode: the value's
 * own current representation, never its text. */
static yyjson_mut_val *JsonBuildMut(Tcl_Interp *interp, yyjson_mut_doc *doc,
                                    Tcl_Obj *v, int depth, const char **err) {
    if (depth >= JSON_MAX_DEPTH) { *err = "value is too deeply nested"; return NULL; }
    if (JsonIsTyped(v)) {
        yyjson_mut_val *m = JsonNodeToMut(doc, v);
        if (m == NULL) *err = "out of memory";
        return m;
    }
    static const Tcl_ObjType *dictType = NULL, *listType = NULL;
    if (dictType == NULL) dictType = Tcl_GetObjType("dict");
    if (listType == NULL) listType = Tcl_GetObjType("list");
    if (v->typePtr != NULL && v->typePtr == dictType) {
        yyjson_mut_val *obj = yyjson_mut_obj(doc);
        Tcl_DictSearch s;
        Tcl_Obj *k, *val;
        int done;
        if (Tcl_DictObjFirst(interp, v, &s, &k, &val, &done) != TCL_OK) {
            *err = "invalid dict";
            return NULL;
        }
        for (; !done; Tcl_DictObjNext(&s, &k, &val, &done)) {
            Tcl_Size kl;
            const char *ks = Tcl_GetStringFromObj(k, &kl);
            yyjson_mut_val *mk = yyjson_mut_strncpy(doc, ks, (size_t)kl);
            yyjson_mut_val *mv = JsonBuildMut(interp, doc, val, depth + 1, err);
            if (mk == NULL || mv == NULL) {
                Tcl_DictObjDone(&s);
                if (*err == NULL) *err = "out of memory";
                return NULL;
            }
            yyjson_mut_obj_add(obj, mk, mv);
        }
        Tcl_DictObjDone(&s);
        return obj;
    }
    if (v->typePtr != NULL && v->typePtr == listType) {
        yyjson_mut_val *arr = yyjson_mut_arr(doc);
        Tcl_Size n;
        Tcl_Obj **el;
        if (Tcl_ListObjGetElements(interp, v, &n, &el) != TCL_OK) {
            *err = "invalid list";
            return NULL;
        }
        for (Tcl_Size i = 0; i < n; i++) {
            yyjson_mut_val *mv = JsonBuildMut(interp, doc, el[i], depth + 1, err);
            if (mv == NULL) { if (*err == NULL) *err = "out of memory"; return NULL; }
            yyjson_mut_arr_append(arr, mv);
        }
        return arr;
    }
    *err = "leaf is not a typed json value (construct it with `json value`)";
    return NULL;
}

/* Plain mapping of a typed node: the shared exit to ordinary Tcl values.
 * Immutable nodes reuse yy_to_tcl; mutable nodes mirror it. */
static Tcl_Obj *yy_mut_to_tcl(yyjson_mut_val *v, int depth, int *depthErr) {
    if (depth >= JSON_MAX_DEPTH) { *depthErr = 1; return NULL; }
    switch (yyjson_mut_get_type(v)) {
        case YYJSON_TYPE_NULL: return Tcl_NewObj();
        case YYJSON_TYPE_BOOL:
            return Tcl_NewIntObj(yyjson_mut_get_bool(v) ? 1 : 0);
        case YYJSON_TYPE_RAW:
            return Tcl_NewStringObj(yyjson_mut_get_raw(v),
                                    (Tcl_Size)yyjson_mut_get_len(v));
        case YYJSON_TYPE_NUM:
        case YYJSON_TYPE_STR:
            return Tcl_NewStringObj(yyjson_mut_get_str(v) != NULL
                    ? yyjson_mut_get_str(v) : "",
                    (Tcl_Size)yyjson_mut_get_len(v));
        case YYJSON_TYPE_ARR: {
            Tcl_Obj *l = Tcl_NewListObj(0, NULL);
            yyjson_mut_arr_iter it;
            yyjson_mut_arr_iter_init(v, &it);
            yyjson_mut_val *el;
            while ((el = yyjson_mut_arr_iter_next(&it)) != NULL) {
                Tcl_Obj *o = yy_mut_to_tcl(el, depth + 1, depthErr);
                if (o == NULL) { Tcl_DecrRefCount(l); return NULL; }
                Tcl_ListObjAppendElement(NULL, l, o);
            }
            return l;
        }
        case YYJSON_TYPE_OBJ: {
            Tcl_Obj *d = Tcl_NewDictObj();
            yyjson_mut_obj_iter it;
            yyjson_mut_obj_iter_init(v, &it);
            yyjson_mut_val *k;
            while ((k = yyjson_mut_obj_iter_next(&it)) != NULL) {
                yyjson_mut_val *val = yyjson_mut_obj_iter_get_val(k);
                Tcl_Obj *ko = Tcl_NewStringObj(yyjson_mut_get_str(k),
                        (Tcl_Size)yyjson_mut_get_len(k));
                Tcl_Obj *vo = yy_mut_to_tcl(val, depth + 1, depthErr);
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
            return NULL;
    }
}

/* The JSON type tag of a node, as the contract names it. RAW nodes are
 * numbers: NUMBER_AS_RAW and the raw constructor are how spelling survives. */
static const char *JsonNodeTag(Tcl_Obj *o) {
    JsonDocWrap *w = JWRAP(o);
    uint8_t t = (w->idoc != NULL)
        ? yyjson_get_type((yyjson_val *)JNODE(o))
        : yyjson_mut_get_type((yyjson_mut_val *)JNODE(o));
    switch (t) {
        case YYJSON_TYPE_NULL: return "null";
        case YYJSON_TYPE_BOOL: return "boolean";
        case YYJSON_TYPE_NUM:  return "number";
        case YYJSON_TYPE_RAW:  return "number";
        case YYJSON_TYPE_STR:  return "string";
        case YYJSON_TYPE_ARR:  return "array";
        case YYJSON_TYPE_OBJ:  return "object";
        default:               return "unknown";
    }
}

/* Strictness for `decode -typed`: duplicate object members refuse at every
 * nesting level (yyjson keeps duplicates in the document; walking is the
 * verified route - the library offers no rejection flag). The same walk
 * enforces the contract's depth cap, which also bounds ITS OWN recursion
 * against the 100000-deep corpus inputs yyjson parses without blinking.
 * Returns 0 with either *badKey set (a duplicate) or *tooDeep set. */
static int JsonCheckStrict(yyjson_val *v, int depth,
                           const char **badKey, int *tooDeep) {
    if (depth >= JSON_MAX_DEPTH) { *tooDeep = 1; return 0; }
    switch (yyjson_get_type(v)) {
        case YYJSON_TYPE_ARR: {
            yyjson_arr_iter it;
            yyjson_arr_iter_init(v, &it);
            yyjson_val *el;
            while ((el = yyjson_arr_iter_next(&it)) != NULL) {
                if (!JsonCheckStrict(el, depth + 1, badKey, tooDeep)) return 0;
            }
            return 1;
        }
        case YYJSON_TYPE_OBJ: {
            yyjson_obj_iter a;
            yyjson_obj_iter_init(v, &a);
            yyjson_val *k;
            while ((k = yyjson_obj_iter_next(&a)) != NULL) {
                const char *ks = yyjson_get_str(k);
                size_t kl = yyjson_get_len(k);
                yyjson_obj_iter b;
                yyjson_obj_iter_init(v, &b);
                yyjson_val *k2;
                int seen = 0;
                while ((k2 = yyjson_obj_iter_next(&b)) != NULL) {
                    if (yyjson_get_len(k2) == kl &&
                        memcmp(yyjson_get_str(k2), ks, kl) == 0) {
                        if (++seen > 1) { *badKey = ks; return 0; }
                    }
                }
                if (!JsonCheckStrict(yyjson_obj_iter_get_val(k), depth + 1,
                                     badKey, tooDeep)) return 0;
            }
            return 1;
        }
        default:
            return 1;
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

static int json_emit(Tcl_Interp *interp, Tcl_Obj *v, Tcl_DString *out, int as_dict, int depth, int plainOnly);

static int json_emit_list(Tcl_Interp *interp, Tcl_Obj *v, Tcl_DString *out, int depth, int plainOnly) {
    Tcl_Size n;
    Tcl_Obj **el;
    if (Tcl_ListObjGetElements(interp, v, &n, &el) != TCL_OK) return TCL_ERROR;
    Tcl_DStringAppend(out, "[", 1);
    for (Tcl_Size i = 0; i < n; i++) {
        if (i) Tcl_DStringAppend(out, ",", 1);
        if (json_emit(interp, el[i], out, 0, depth + 1, plainOnly) != TCL_OK) return TCL_ERROR;
    }
    Tcl_DStringAppend(out, "]", 1);
    return TCL_OK;
}

static int json_emit_dict(Tcl_Interp *interp, Tcl_Obj *v, Tcl_DString *out, int depth, int plainOnly) {
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
        if (json_emit(interp, val, out, 0, depth + 1, plainOnly) != TCL_OK) {
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
static int json_emit(Tcl_Interp *interp, Tcl_Obj *v, Tcl_DString *out, int as_dict, int depth, int plainOnly) {
    if (depth >= JSON_MAX_DEPTH) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("value is too deeply nested", -1));
        Tcl_SetErrorCode(interp, "MACHTELD", "JSON", "depth", (char *)NULL);
        return TCL_ERROR;
    }
    /* Typed values are recognized at every nesting level and written by the
     * typed writer. On the -plain path used by worker and pool protocols they
     * refuse by name instead, preserving the distinction typed mode exists to
     * provide. */
    if (JsonIsTyped(v)) {
        if (plainOnly) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj(
                "typed json value refused on a plain-only path", -1));
            Tcl_SetErrorCode(interp, "MACHTELD", "JSON", "type", (char *)NULL);
            return TCL_ERROR;
        }
        size_t n = 0;
        char *s = JsonNodeWrite(v, &n);
        if (s == NULL) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("typed value write failed", -1));
            Tcl_SetErrorCode(interp, "MACHTELD", "JSON", "type", (char *)NULL);
            return TCL_ERROR;
        }
        Tcl_DStringAppend(out, s, (Tcl_Size)n);
        free(s);
        return TCL_OK;
    }
    if (as_dict) return json_emit_dict(interp, v, out, depth, plainOnly);

    static const Tcl_ObjType *dictType = NULL, *listType = NULL;
    if (dictType == NULL) dictType = Tcl_GetObjType("dict");
    if (listType == NULL) listType = Tcl_GetObjType("list");

    const Tcl_ObjType *t = v->typePtr;
    if (t != NULL && t == dictType) return json_emit_dict(interp, v, out, depth, plainOnly);
    if (t != NULL && t == listType) return json_emit_list(interp, v, out, depth, plainOnly);

    Tcl_Size n;
    const char *s = Tcl_GetStringFromObj(v, &n);
    if (json_is_number_literal(s, n)) { Tcl_DStringAppend(out, s, n); return TCL_OK; }
    json_quote(out, s, n);
    return TCL_OK;
}

/* ---- the verb ----------------------------------------------------------- */

/* The typed decode's byte limits: a documented default, a documented hard
 * cap, and -maxbytes may only ask for LESS than the cap (the organ does not
 * infer what a caller bounded elsewhere - the handoff's own law). */
#define JSON_TYPED_DEFAULT_MAXBYTES (16u * 1024u * 1024u)
#define JSON_TYPED_HARD_MAXBYTES    (64u * 1024u * 1024u)

static int JsonErr(Tcl_Interp *interp, const char *code, const char *msg) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "JSON", code, (char *)NULL);
    return TCL_ERROR;
}

/* Resolve one get/exists path step against a typed node. Returns the child
 * node or NULL; *stepErr distinguishes absent from a non-container. */
static void *JsonStep(JsonDocWrap *w, void *node, Tcl_Obj *step, int *stepErr) {
    Tcl_Size sl;
    const char *ss = Tcl_GetStringFromObj(step, &sl);
    *stepErr = 0;
    if (w->idoc != NULL) {
        yyjson_val *v = (yyjson_val *)node;
        if (yyjson_is_obj(v)) return yyjson_obj_getn(v, ss, (size_t)sl);
        if (yyjson_is_arr(v)) {
            Tcl_WideInt i;
            if (Tcl_GetWideIntFromObj(NULL, step, &i) != TCL_OK || i < 0) {
                *stepErr = 1;
                return NULL;
            }
            return yyjson_arr_get(v, (size_t)i);
        }
        *stepErr = 1;
        return NULL;
    }
    yyjson_mut_val *v = (yyjson_mut_val *)node;
    if (yyjson_mut_is_obj(v)) return yyjson_mut_obj_getn(v, ss, (size_t)sl);
    if (yyjson_mut_is_arr(v)) {
        Tcl_WideInt i;
        if (Tcl_GetWideIntFromObj(NULL, step, &i) != TCL_OK || i < 0) {
            *stepErr = 1;
            return NULL;
        }
        return yyjson_mut_arr_get(v, (size_t)i);
    }
    *stepErr = 1;
    return NULL;
}

static int JsonCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    static const char *const subs[] = {
        "decode", "encode", "value", "type", "unwrap", "get", "exists", NULL
    };
    enum { DECODE, ENCODE, VALUE, TYPE, UNWRAP, GET, EXISTS };
    int idx;
    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "subcommand ?arg ...?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", TCL_EXACT, &idx) != TCL_OK) return TCL_ERROR;

    if (idx == DECODE) {
        int typed = 0;
        int maxBytesSet = 0;
        Tcl_WideInt maxBytes = JSON_TYPED_DEFAULT_MAXBYTES;
        Tcl_Obj *textObj = NULL;
        for (int i = 2; i < objc; i++) {
            const char *a = Tcl_GetString(objv[i]);
            if (textObj == NULL && strcmp(a, "-typed") == 0) { typed = 1; continue; }
            if (textObj == NULL && strcmp(a, "-maxbytes") == 0) {
                if (i + 1 >= objc ||
                    Tcl_GetWideIntFromObj(NULL, objv[i + 1], &maxBytes) != TCL_OK ||
                    maxBytes < 1) {
                    return JsonErr(interp, "usage", "-maxbytes needs a positive byte count");
                }
                maxBytesSet = 1;
                i++;
                continue;
            }
            if (textObj != NULL) {
                return JsonErr(interp, "usage", "unknown option");
            }
            textObj = objv[i];
        }
        if (textObj == NULL) {
            Tcl_WrongNumArgs(interp, 2, objv, "?-typed? ?-maxbytes N? text");
            return TCL_ERROR;
        }
        if (!typed && maxBytesSet) {
            return JsonErr(interp, "usage", "-maxbytes applies to -typed decode");
        }
        Tcl_Size n;
        const char *s = Tcl_GetStringFromObj(textObj, &n);
        if (typed) {
            if (maxBytes > (Tcl_WideInt)JSON_TYPED_HARD_MAXBYTES) {
                return JsonErr(interp, "limit",
                    "-maxbytes is above the documented hard cap (64 MiB)");
            }
            if ((Tcl_WideInt)n > maxBytes) {
                return JsonErr(interp, "limit", "document exceeds -maxbytes");
            }
        }
        yyjson_read_err rerr;
        yyjson_doc *doc = yyjson_read_opts((char *)s, (size_t)n,
            YYJSON_READ_NUMBER_AS_RAW, NULL, &rerr);
        if (doc == NULL) {
            char msg[192];
            snprintf(msg, sizeof msg, "%s (byte %zu)",
                     rerr.msg ? rerr.msg : "invalid JSON", rerr.pos);
            return JsonErr(interp, "parse", msg);
        }
        if (typed) {
            const char *badKey = NULL;
            int tooDeep = 0;
            if (!JsonCheckStrict(yyjson_doc_get_root(doc), 0, &badKey, &tooDeep)) {
                yyjson_doc_free(doc);
                if (tooDeep) return JsonErr(interp, "depth", "too deeply nested");
                char msg[160];
                snprintf(msg, sizeof msg, "duplicate object key \"%.80s\"",
                         badKey ? badKey : "");
                return JsonErr(interp, "strict", msg);
            }
            JsonDocWrap *w = (JsonDocWrap *)Tcl_Alloc(sizeof(JsonDocWrap));
            w->refCount = 0;
            w->idoc = doc;
            w->mdoc = NULL;
            Tcl_SetObjResult(interp, JsonNewTyped(w, yyjson_doc_get_root(doc)));
            return TCL_OK;
        }
        int depthErr = 0;
        Tcl_Obj *v = yy_to_tcl(yyjson_doc_get_root(doc), 0, &depthErr);
        yyjson_doc_free(doc);
        if (v == NULL) {
            return JsonErr(interp, depthErr ? "depth" : "parse",
                depthErr ? "too deeply nested" : "invalid JSON");
        }
        Tcl_SetObjResult(interp, v);
        return TCL_OK;
    }

    if (idx == VALUE) {
        static const char *const kinds[] = {
            "string", "number", "boolean", "null", "array", "object", NULL
        };
        enum { KSTRING, KNUMBER, KBOOLEAN, KNULL, KARRAY, KOBJECT };
        int kind;
        if (objc < 3) {
            Tcl_WrongNumArgs(interp, 2, objv, "kind ?value?");
            return TCL_ERROR;
        }
        if (Tcl_GetIndexFromObj(interp, objv[2], kinds, "kind", TCL_EXACT, &kind) != TCL_OK) return TCL_ERROR;
        if ((kind == KNULL && objc != 3) || (kind != KNULL && objc != 4)) {
            Tcl_WrongNumArgs(interp, 3, objv, kind == KNULL ? NULL : "value");
            return TCL_ERROR;
        }
        yyjson_mut_doc *doc = yyjson_mut_doc_new(NULL);
        if (doc == NULL) return JsonErr(interp, "limit", "out of memory");
        yyjson_mut_val *node = NULL;
        const char *err = NULL;
        switch (kind) {
            case KSTRING: {
                Tcl_Size sl;
                const char *ss = Tcl_GetStringFromObj(objv[3], &sl);
                node = yyjson_mut_strncpy(doc, ss, (size_t)sl);
                break;
            }
            case KNUMBER: {
                Tcl_Size sl;
                const char *ss = Tcl_GetStringFromObj(objv[3], &sl);
                /* The number gate: the ONLY position where caller bytes
                 * reach the wire unquoted gets the exact JSON grammar,
                 * fail-closed (the panel's raw-escape-hatch finding). */
                if (!json_is_number_literal(ss, sl)) {
                    yyjson_mut_doc_free(doc);
                    return JsonErr(interp, "type",
                        "not a JSON number literal");
                }
                node = yyjson_mut_rawncpy(doc, ss, (size_t)sl);
                break;
            }
            case KBOOLEAN: {
                int b;
                if (Tcl_GetBooleanFromObj(interp, objv[3], &b) != TCL_OK) {
                    yyjson_mut_doc_free(doc);
                    return TCL_ERROR;
                }
                node = yyjson_mut_bool(doc, b != 0);
                break;
            }
            case KNULL:
                node = yyjson_mut_null(doc);
                break;
            case KARRAY: {
                Tcl_Size an;
                Tcl_Obj **el;
                if (Tcl_ListObjGetElements(interp, objv[3], &an, &el) != TCL_OK) {
                    yyjson_mut_doc_free(doc);
                    return TCL_ERROR;
                }
                node = yyjson_mut_arr(doc);
                for (Tcl_Size i = 0; node != NULL && i < an; i++) {
                    yyjson_mut_val *mv = JsonBuildMut(interp, doc, el[i], 1, &err);
                    if (mv == NULL) { node = NULL; break; }
                    yyjson_mut_arr_append(node, mv);
                }
                break;
            }
            case KOBJECT: {
                Tcl_DictSearch ds;
                Tcl_Obj *k, *val;
                int done;
                if (Tcl_DictObjFirst(interp, objv[3], &ds, &k, &val, &done) != TCL_OK) {
                    yyjson_mut_doc_free(doc);
                    return TCL_ERROR;
                }
                node = yyjson_mut_obj(doc);
                for (; node != NULL && !done; Tcl_DictObjNext(&ds, &k, &val, &done)) {
                    Tcl_Size kl;
                    const char *ks = Tcl_GetStringFromObj(k, &kl);
                    yyjson_mut_val *mk = yyjson_mut_strncpy(doc, ks, (size_t)kl);
                    yyjson_mut_val *mv = JsonBuildMut(interp, doc, val, 1, &err);
                    if (mk == NULL || mv == NULL) { node = NULL; break; }
                    yyjson_mut_obj_add(node, mk, mv);
                }
                Tcl_DictObjDone(&ds);
                break;
            }
        }
        if (node == NULL) {
            yyjson_mut_doc_free(doc);
            return JsonErr(interp, "type",
                err != NULL ? err : "out of memory");
        }
        JsonDocWrap *w = (JsonDocWrap *)Tcl_Alloc(sizeof(JsonDocWrap));
        w->refCount = 0;
        w->idoc = NULL;
        w->mdoc = doc;
        Tcl_SetObjResult(interp, JsonNewTyped(w, node));
        return TCL_OK;
    }

    if (idx == TYPE || idx == UNWRAP) {
        if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "value"); return TCL_ERROR; }
        if (!JsonIsTyped(objv[2])) {
            return JsonErr(interp, "type", "not a typed json value");
        }
        if (idx == TYPE) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj(JsonNodeTag(objv[2]), -1));
            return TCL_OK;
        }
        JsonDocWrap *w = JWRAP(objv[2]);
        int depthErr = 0;
        Tcl_Obj *v = (w->idoc != NULL)
            ? yy_to_tcl((yyjson_val *)JNODE(objv[2]), 0, &depthErr)
            : yy_mut_to_tcl((yyjson_mut_val *)JNODE(objv[2]), 0, &depthErr);
        if (v == NULL) {
            return JsonErr(interp, depthErr ? "depth" : "type",
                depthErr ? "too deeply nested" : "cannot unwrap");
        }
        Tcl_SetObjResult(interp, v);
        return TCL_OK;
    }

    if (idx == GET || idx == EXISTS) {
        if (objc < 3) {
            Tcl_WrongNumArgs(interp, 2, objv, "value ?key|index ...?");
            return TCL_ERROR;
        }
        if (!JsonIsTyped(objv[2])) {
            return JsonErr(interp, "type", "not a typed json value");
        }
        JsonDocWrap *w = JWRAP(objv[2]);
        void *node = JNODE(objv[2]);
        for (int i = 3; i < objc; i++) {
            int stepErr = 0;
            node = JsonStep(w, node, objv[i], &stepErr);
            if (node == NULL) {
                if (idx == EXISTS) {
                    Tcl_SetObjResult(interp, Tcl_NewIntObj(0));
                    return TCL_OK;
                }
                if (stepErr) {
                    return JsonErr(interp, "type",
                        "path steps into a non-container");
                }
                char msg[160];
                snprintf(msg, sizeof msg, "no member \"%.80s\"",
                         Tcl_GetString(objv[i]));
                return JsonErr(interp, "absent", msg);
            }
        }
        if (idx == EXISTS) {
            Tcl_SetObjResult(interp, Tcl_NewIntObj(1));
            return TCL_OK;
        }
        Tcl_SetObjResult(interp, JsonNewTyped(w, node));
        return TCL_OK;
    }

    /* Keep ENCODE explicit rather than relying on fall-through; the two public
     * branches then remain independently readable and testable. */
    if (idx == ENCODE) {
    int as_dict = 0, as_list = 0, plainOnly = 0, options = 1;
    Tcl_Obj *val = NULL;
    for (int i = 2; i < objc; i++) {
        const char *a = Tcl_GetString(objv[i]);
        if (options && strcmp(a, "--") == 0) { options = 0; continue; }
        if (options && strcmp(a, "-dict") == 0) { as_dict = 1; continue; }
        if (options && strcmp(a, "-list") == 0) { as_list = 1; continue; }
        if (options && strcmp(a, "-plain") == 0) { plainOnly = 1; continue; }
        if (val != NULL) {
            return JsonErr(interp, "usage", "unknown option");
        }
        val = objv[i];
    }
    if (val == NULL) { Tcl_WrongNumArgs(interp, 2, objv, "?-dict|-list? ?-plain? value"); return TCL_ERROR; }
    if (as_dict && as_list) {
        return JsonErr(interp, "usage", "-dict and -list are exclusive");
    }

    Tcl_DString out;
    Tcl_DStringInit(&out);
    if (as_list) {
        if (json_emit_list(interp, val, &out, 0, plainOnly) != TCL_OK) { Tcl_DStringFree(&out); return TCL_ERROR; }
        Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_DStringValue(&out), Tcl_DStringLength(&out)));
        Tcl_DStringFree(&out);
        return TCL_OK;
    }
    if (json_emit(interp, val, &out, as_dict, 0, plainOnly) != TCL_OK) {
        Tcl_DStringFree(&out);
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_DStringValue(&out), Tcl_DStringLength(&out)));
    Tcl_DStringFree(&out);
    return TCL_OK;
    }
    return TCL_OK;   /* unreachable: Tcl_GetIndexFromObj admits every branch */
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
