/*
 * json.c -- ::machteld::json encode|decode, hand-rolled straight into Tcl_Obj.
 *
 * The contract says everything is a dict and that dicts are JSON-isomorphic;
 * Tcl 9 core ships no JSON, so this closes the one real gap in it.
 *
 * WHY HAND-ROLLED. The ecosystem policy's gate is "can I own this snapshot",
 * and a vendored parser is a large optimised snapshot admitted on trust. What a
 * borrowed parser would actually save is the tokeniser -- perhaps a third of
 * this file -- because the Tcl_Obj construction, the type mapping, the
 * encode-side ambiguity and the depth limit all have to be written either way.
 * So the SUITE is vendored instead of the implementation: test/jsontestsuite is
 * nst/JSONTestSuite, 318 cases, run as a gate. Correctness comes from the
 * corpus, not from trust.
 *
 * THE MAPPING, which is the hard part rather than the parsing. Tcl has no type
 * tags, so JSON's types do not survive a round trip unaided:
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
 * booleans and nulls do not round-trip. Both are documented in the contract.
 */
#undef USE_TCL_STUBS
#include <tcl.h>
#include <string.h>
#include <stdlib.h>

/* Nesting cap. JSONTestSuite deliberately includes 100000-deep input; a
 * recursive-descent parser must refuse rather than exhaust its stack. 512 is
 * far past any real document and leaves the i_structure_500_nested_arrays case
 * (implementation-defined) parsing successfully. */
#define JSON_MAX_DEPTH 512

typedef struct {
    const char *p;
    const char *end;
    int         depth;
    const char *err;
} jctx;

static Tcl_Obj *json_value(jctx *j);

static int json_err(jctx *j, const char *msg) {
    if (j->err == NULL) j->err = msg;
    return 0;
}

static void json_ws(jctx *j) {
    while (j->p < j->end) {
        char c = *j->p;
        /* Exactly the four JSON whitespace bytes -- not isspace(), which would
         * also accept \f and \v and quietly widen the grammar. */
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') j->p++;
        else break;
    }
}

/* Append one code point as UTF-8. Tcl 9 stores strings as UTF-8, so building
 * the bytes directly avoids a second conversion. */
static void json_utf8(Tcl_DString *out, unsigned cp) {
    char b[4];
    if (cp < 0x80) {
        b[0] = (char)cp;
        Tcl_DStringAppend(out, b, 1);
    } else if (cp < 0x800) {
        b[0] = (char)(0xC0 | (cp >> 6));
        b[1] = (char)(0x80 | (cp & 0x3F));
        Tcl_DStringAppend(out, b, 2);
    } else if (cp < 0x10000) {
        b[0] = (char)(0xE0 | (cp >> 12));
        b[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = (char)(0x80 | (cp & 0x3F));
        Tcl_DStringAppend(out, b, 3);
    } else {
        b[0] = (char)(0xF0 | (cp >> 18));
        b[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        b[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[3] = (char)(0x80 | (cp & 0x3F));
        Tcl_DStringAppend(out, b, 4);
    }
}

static int json_hex4(jctx *j, unsigned *out) {
    unsigned v = 0;
    if (j->end - j->p < 4) return json_err(j, "truncated \\u escape");
    for (int i = 0; i < 4; i++) {
        char c = j->p[i];
        v <<= 4;
        if (c >= '0' && c <= '9')      v |= (unsigned)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
        else return json_err(j, "bad \\u escape");
    }
    j->p += 4;
    *out = v;
    return 1;
}

/* Validate one UTF-8 sequence, rejecting overlongs, surrogates encoded as
 * UTF-8, and anything past U+10FFFF. JSONTestSuite has a whole family of these
 * (n_string_invalid_utf8_*), and letting them through would mean Tcl holding a
 * string whose bytes are not valid UTF-8 -- corruption that surfaces later,
 * somewhere else. */
static int json_utf8_ok(jctx *j, const unsigned char c) {
    int need;
    unsigned cp;
    if (c < 0x80) return 1;
    else if ((c & 0xE0) == 0xC0) { need = 1; cp = c & 0x1Fu; }
    else if ((c & 0xF0) == 0xE0) { need = 2; cp = c & 0x0Fu; }
    else if ((c & 0xF8) == 0xF0) { need = 3; cp = c & 0x07u; }
    else return json_err(j, "invalid UTF-8 lead byte");
    if (j->end - j->p < need) return json_err(j, "truncated UTF-8 sequence");
    for (int i = 0; i < need; i++) {
        unsigned char cc = (unsigned char)j->p[i];
        if ((cc & 0xC0) != 0x80) return json_err(j, "invalid UTF-8 continuation");
        cp = (cp << 6) | (cc & 0x3Fu);
    }
    j->p += need;
    if (need == 1 && cp < 0x80)     return json_err(j, "overlong UTF-8");
    if (need == 2 && cp < 0x800)    return json_err(j, "overlong UTF-8");
    if (need == 3 && cp < 0x10000)  return json_err(j, "overlong UTF-8");
    if (cp > 0x10FFFF)              return json_err(j, "UTF-8 out of range");
    if (cp >= 0xD800 && cp <= 0xDFFF) return json_err(j, "UTF-8 encoded surrogate");
    return 1;
}

static Tcl_Obj *json_string(jctx *j) {
    Tcl_DString ds;
    Tcl_DStringInit(&ds);
    j->p++; /* the opening quote */
    for (;;) {
        if (j->p >= j->end) { json_err(j, "unterminated string"); goto fail; }
        unsigned char c = (unsigned char)*j->p;
        if (c == '"') {
            j->p++;
            Tcl_Obj *o = Tcl_NewStringObj(Tcl_DStringValue(&ds), Tcl_DStringLength(&ds));
            Tcl_DStringFree(&ds);
            return o;
        }
        if (c < 0x20) { json_err(j, "unescaped control character in string"); goto fail; }
        if (c == '\\') {
            j->p++;
            if (j->p >= j->end) { json_err(j, "trailing backslash"); goto fail; }
            char e = *j->p++;
            switch (e) {
                case '"':  Tcl_DStringAppend(&ds, "\"", 1); break;
                case '\\': Tcl_DStringAppend(&ds, "\\", 1); break;
                case '/':  Tcl_DStringAppend(&ds, "/", 1);  break;
                case 'b':  Tcl_DStringAppend(&ds, "\b", 1); break;
                case 'f':  Tcl_DStringAppend(&ds, "\f", 1); break;
                case 'n':  Tcl_DStringAppend(&ds, "\n", 1); break;
                case 'r':  Tcl_DStringAppend(&ds, "\r", 1); break;
                case 't':  Tcl_DStringAppend(&ds, "\t", 1); break;
                case 'u': {
                    unsigned u;
                    if (!json_hex4(j, &u)) goto fail;
                    if (u >= 0xD800 && u <= 0xDBFF) {
                        /* A high surrogate needs its pair. An unpaired one is
                         * syntactically legal JSON but cannot be a character,
                         * so it becomes U+FFFD rather than a byte sequence Tcl
                         * would carry as invalid UTF-8. */
                        if (j->end - j->p >= 2 && j->p[0] == '\\' && j->p[1] == 'u') {
                            const char *save = j->p;
                            j->p += 2;
                            unsigned lo;
                            if (!json_hex4(j, &lo)) goto fail;
                            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                                json_utf8(&ds, 0x10000u + ((u - 0xD800u) << 10) + (lo - 0xDC00u));
                                break;
                            }
                            j->p = save;
                        }
                        json_utf8(&ds, 0xFFFD);
                        break;
                    }
                    if (u >= 0xDC00 && u <= 0xDFFF) { json_utf8(&ds, 0xFFFD); break; }
                    json_utf8(&ds, u);
                    break;
                }
                default: json_err(j, "bad escape"); goto fail;
            }
            continue;
        }
        if (c < 0x80) { Tcl_DStringAppend(&ds, (const char *)j->p, 1); j->p++; continue; }
        {
            const char *start = j->p;
            j->p++;
            if (!json_utf8_ok(j, c)) goto fail;
            Tcl_DStringAppend(&ds, start, (Tcl_Size)(j->p - start));
        }
    }
fail:
    Tcl_DStringFree(&ds);
    return NULL;
}

/* JSON's number grammar exactly: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
 * No leading +, no leading zeros, no bare ".5" or "5.", no hex, no Inf/NaN. The
 * literal text is kept verbatim -- Tcl 9 has bignums, so a 40-digit integer
 * survives exactly, and re-encoding is byte-identical. */
static Tcl_Obj *json_number(jctx *j) {
    const char *start = j->p;
    if (j->p < j->end && *j->p == '-') j->p++;
    if (j->p >= j->end) { json_err(j, "bad number"); return NULL; }
    if (*j->p == '0') {
        j->p++;
    } else if (*j->p >= '1' && *j->p <= '9') {
        while (j->p < j->end && *j->p >= '0' && *j->p <= '9') j->p++;
    } else {
        json_err(j, "bad number");
        return NULL;
    }
    if (j->p < j->end && *j->p == '.') {
        j->p++;
        if (j->p >= j->end || *j->p < '0' || *j->p > '9') { json_err(j, "bad fraction"); return NULL; }
        while (j->p < j->end && *j->p >= '0' && *j->p <= '9') j->p++;
    }
    if (j->p < j->end && (*j->p == 'e' || *j->p == 'E')) {
        j->p++;
        if (j->p < j->end && (*j->p == '+' || *j->p == '-')) j->p++;
        if (j->p >= j->end || *j->p < '0' || *j->p > '9') { json_err(j, "bad exponent"); return NULL; }
        while (j->p < j->end && *j->p >= '0' && *j->p <= '9') j->p++;
    }
    return Tcl_NewStringObj(start, (Tcl_Size)(j->p - start));
}

static Tcl_Obj *json_array(jctx *j) {
    Tcl_Obj *l = Tcl_NewListObj(0, NULL);
    j->p++;
    json_ws(j);
    if (j->p < j->end && *j->p == ']') { j->p++; return l; }
    for (;;) {
        Tcl_Obj *v = json_value(j);
        if (v == NULL) { Tcl_DecrRefCount(l); return NULL; }
        Tcl_ListObjAppendElement(NULL, l, v);
        json_ws(j);
        if (j->p < j->end && *j->p == ',') { j->p++; json_ws(j); continue; }
        if (j->p < j->end && *j->p == ']') { j->p++; return l; }
        json_err(j, "expected , or ] in array");
        Tcl_DecrRefCount(l);
        return NULL;
    }
}

static Tcl_Obj *json_object(jctx *j) {
    Tcl_Obj *d = Tcl_NewDictObj();
    j->p++;
    json_ws(j);
    if (j->p < j->end && *j->p == '}') { j->p++; return d; }
    for (;;) {
        json_ws(j);
        if (j->p >= j->end || *j->p != '"') { json_err(j, "expected a string key"); goto fail; }
        Tcl_Obj *k = json_string(j);
        if (k == NULL) goto fail;
        json_ws(j);
        if (j->p >= j->end || *j->p != ':') { Tcl_DecrRefCount(k); json_err(j, "expected :"); goto fail; }
        j->p++;
        Tcl_Obj *v = json_value(j);
        if (v == NULL) { Tcl_DecrRefCount(k); goto fail; }
        /* A duplicate key overwrites, which is what a Tcl dict does anyway and
         * what the JSON spec permits ("the last value wins" is the common
         * reading of an undefined case). */
        Tcl_DictObjPut(NULL, d, k, v);
        json_ws(j);
        if (j->p < j->end && *j->p == ',') { j->p++; continue; }
        if (j->p < j->end && *j->p == '}') { j->p++; return d; }
        json_err(j, "expected , or } in object");
        goto fail;
    }
fail:
    Tcl_DecrRefCount(d);
    return NULL;
}

static Tcl_Obj *json_value(jctx *j) {
    if (j->depth >= JSON_MAX_DEPTH) { json_err(j, "too deeply nested"); return NULL; }
    json_ws(j);
    if (j->p >= j->end) { json_err(j, "unexpected end of input"); return NULL; }
    char c = *j->p;
    Tcl_Obj *r = NULL;
    j->depth++;
    switch (c) {
        case '{': r = json_object(j); break;
        case '[': r = json_array(j);  break;
        case '"': r = json_string(j); break;
        case 't':
            if (j->end - j->p >= 4 && memcmp(j->p, "true", 4) == 0) { j->p += 4; r = Tcl_NewIntObj(1); }
            else json_err(j, "bad literal");
            break;
        case 'f':
            if (j->end - j->p >= 5 && memcmp(j->p, "false", 5) == 0) { j->p += 5; r = Tcl_NewIntObj(0); }
            else json_err(j, "bad literal");
            break;
        case 'n':
            if (j->end - j->p >= 4 && memcmp(j->p, "null", 4) == 0) { j->p += 4; r = Tcl_NewObj(); }
            else json_err(j, "bad literal");
            break;
        default:
            if (c == '-' || (c >= '0' && c <= '9')) r = json_number(j);
            else json_err(j, "unexpected character");
            break;
    }
    j->depth--;
    return r;
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
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", 0, &idx) != TCL_OK) return TCL_ERROR;

    if (idx == DECODE) {
        if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "text"); return TCL_ERROR; }
        Tcl_Size n;
        const char *s = Tcl_GetStringFromObj(objv[2], &n);
        jctx j = { s, s + n, 0, NULL };
        Tcl_Obj *v = json_value(&j);
        if (v != NULL) {
            json_ws(&j);
            if (j.p != j.end) {
                Tcl_DecrRefCount(v);
                v = NULL;
                j.err = "trailing content after the value";
            }
        }
        if (v == NULL) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj(j.err ? j.err : "invalid JSON", -1));
            Tcl_SetErrorCode(interp, "MACHTELD", "JSON", "parse", (char *)NULL);
            return TCL_ERROR;
        }
        Tcl_SetObjResult(interp, v);
        return TCL_OK;
    }

    /* ENCODE */
    int as_dict = 0, as_list = 0;
    Tcl_Obj *val = NULL;
    for (int i = 2; i < objc; i++) {
        const char *a = Tcl_GetString(objv[i]);
        if (strcmp(a, "-dict") == 0) { as_dict = 1; continue; }
        if (strcmp(a, "-list") == 0) { as_list = 1; continue; }
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

int Machteldjson_Init(Tcl_Interp *interp) {
    Tcl_CreateObjCommand(interp, "::machteld::json", JsonCmd, NULL, NULL);
    Tcl_PkgProvide(interp, "machteld::json", "0.1");
    return TCL_OK;
}
