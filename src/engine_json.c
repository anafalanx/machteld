/* engine_json.c -- strict, bounded JSON for the engine's control plane.
 * See engine_json.h for the contract. */

#include "engine_json.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <errno.h>

#define EJ_MAX_DEPTH 32

/* ---------------- output buffer ---------------- */

void
EjBufInit(EjBuf *b)
{
    b->bytes = NULL;
    b->len = 0;
    b->cap = 0;
    b->oom = 0;
}

void
EjBufFree(EjBuf *b)
{
    free(b->bytes);
    EjBufInit(b);
}

static int
EjBufReserve(EjBuf *b, size_t extra)
{
    if (b->oom) {
        return 0;
    }
    if (b->len + extra + 1 <= b->cap) {
        return 1;
    }
    size_t cap = (b->cap == 0) ? 256 : b->cap;
    while (cap < b->len + extra + 1) {
        cap *= 2;
    }
    char *p = (char *)realloc(b->bytes, cap);
    if (p == NULL) {
        b->oom = 1;
        return 0;
    }
    b->bytes = p;
    b->cap = cap;
    return 1;
}

void
EjBufRaw(EjBuf *b, const char *s, size_t n)
{
    if (!EjBufReserve(b, n)) {
        return;
    }
    memcpy(b->bytes + b->len, s, n);
    b->len += n;
    b->bytes[b->len] = '\0';
}

void
EjBufText(EjBuf *b, const char *s)
{
    EjBufRaw(b, s, strlen(s));
}

void
EjBufInt(EjBuf *b, int64_t v)
{
    char tmp[32];
    int n = snprintf(tmp, sizeof(tmp), "%lld", (long long)v);
    EjBufRaw(b, tmp, (size_t)n);
}

void
EjBufDouble(EjBuf *b, double v)
{
    /* Callers route non-finite values through the tagged-object convention;
     * this emitter refuses to produce invalid JSON for them. */
    char tmp[40];
    if (!isfinite(v)) {
        EjBufText(b, "null");
        return;
    }
    int n = snprintf(tmp, sizeof(tmp), "%.17g", v);
    /* Guarantee the double stays a double on re-parse. */
    if (memchr(tmp, '.', (size_t)n) == NULL &&
            memchr(tmp, 'e', (size_t)n) == NULL &&
            memchr(tmp, 'E', (size_t)n) == NULL) {
        n += snprintf(tmp + n, sizeof(tmp) - (size_t)n, ".0");
    }
    EjBufRaw(b, tmp, (size_t)n);
}

void
EjBufString(EjBuf *b, const char *s, size_t n)
{
    static const char hex[] = "0123456789abcdef";
    EjBufRaw(b, "\"", 1);
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"':  EjBufRaw(b, "\\\"", 2); break;
        case '\\': EjBufRaw(b, "\\\\", 2); break;
        case '\b': EjBufRaw(b, "\\b", 2); break;
        case '\f': EjBufRaw(b, "\\f", 2); break;
        case '\n': EjBufRaw(b, "\\n", 2); break;
        case '\r': EjBufRaw(b, "\\r", 2); break;
        case '\t': EjBufRaw(b, "\\t", 2); break;
        default:
            if (c < 0x20) {
                char esc[7] = { '\\', 'u', '0', '0', 0, 0, 0 };
                esc[4] = hex[(c >> 4) & 15];
                esc[5] = hex[c & 15];
                EjBufRaw(b, esc, 6);
            } else {
                EjBufRaw(b, (const char *)&s[i], 1);
            }
        }
    }
    EjBufRaw(b, "\"", 1);
}

/* ---------------- value tree ---------------- */

static Ej *
EjNew(EjKind kind)
{
    Ej *v = (Ej *)calloc(1, sizeof(Ej));
    if (v != NULL) {
        v->kind = kind;
    }
    return v;
}

void
EjFree(Ej *v)
{
    if (v == NULL) {
        return;
    }
    switch (v->kind) {
    case EJ_STRING:
        free(v->u.s.bytes);
        break;
    case EJ_ARRAY:
        for (size_t i = 0; i < v->u.a.count; i++) {
            EjFree(v->u.a.items[i]);
        }
        free(v->u.a.items);
        break;
    case EJ_OBJECT:
        for (size_t i = 0; i < v->u.a.count * 2; i++) {
            EjFree(v->u.a.items[i]);
        }
        free(v->u.a.items);
        break;
    default:
        break;
    }
    free(v);
}

Ej *
EjGet(const Ej *obj, const char *key)
{
    if (obj == NULL || obj->kind != EJ_OBJECT) {
        return NULL;
    }
    for (size_t i = 0; i < obj->u.a.count; i++) {
        Ej *k = obj->u.a.items[i * 2];
        if (k->kind == EJ_STRING && strcmp(k->u.s.bytes, key) == 0) {
            return obj->u.a.items[i * 2 + 1];
        }
    }
    return NULL;
}

/* ---------------- parser ---------------- */

typedef struct {
    const char *p;
    const char *end;
    const char *err;
    int depth;
} EjParser;

static Ej *ParseValue(EjParser *ps);

static void
SkipWs(EjParser *ps)
{
    while (ps->p < ps->end && (*ps->p == ' ' || *ps->p == '\t' ||
            *ps->p == '\n' || *ps->p == '\r')) {
        ps->p++;
    }
}

static int
Lit(EjParser *ps, const char *word)
{
    size_t n = strlen(word);
    if ((size_t)(ps->end - ps->p) >= n && memcmp(ps->p, word, n) == 0) {
        ps->p += n;
        return 1;
    }
    ps->err = "invalid literal";
    return 0;
}

static int
AppendAt(Ej *cont, Ej *item, size_t slot)
{
    /* Slots are written strictly in order 0,1,2,...; regrow at each power
     * of two to a capacity that always covers the incoming slot. count is
     * item count for arrays and PAIR count for objects, and is advanced by
     * the caller only after every slot of the entry is committed. */
    if (slot == 0 || (slot & (slot - 1)) == 0) {
        size_t cap = (slot * 2 < 4) ? 4 : slot * 2;
        Ej **np = (Ej **)realloc(cont->u.a.items, cap * sizeof(Ej *));
        if (np == NULL) {
            return 0;
        }
        cont->u.a.items = np;
    }
    cont->u.a.items[slot] = item;
    return 1;
}

static int
HexVal(char c)
{
    if (c >= '0' && c <= '9') { return c - '0'; }
    if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
    if (c >= 'A' && c <= 'F') { return c - 'A' + 10; }
    return -1;
}

static int
Utf8Emit(EjBuf *b, uint32_t cp)
{
    char t[4];
    if (cp < 0x80) {
        t[0] = (char)cp;
        EjBufRaw(b, t, 1);
    } else if (cp < 0x800) {
        t[0] = (char)(0xC0 | (cp >> 6));
        t[1] = (char)(0x80 | (cp & 0x3F));
        EjBufRaw(b, t, 2);
    } else if (cp < 0x10000) {
        t[0] = (char)(0xE0 | (cp >> 12));
        t[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        t[2] = (char)(0x80 | (cp & 0x3F));
        EjBufRaw(b, t, 3);
    } else {
        t[0] = (char)(0xF0 | (cp >> 18));
        t[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        t[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        t[3] = (char)(0x80 | (cp & 0x3F));
        EjBufRaw(b, t, 4);
    }
    return 1;
}

static Ej *
ParseString(EjParser *ps)
{
    EjBuf out;
    EjBufInit(&out);
    ps->p++;                                   /* opening quote */
    while (ps->p < ps->end) {
        unsigned char c = (unsigned char)*ps->p;
        if (c == '"') {
            ps->p++;
            Ej *v = EjNew(EJ_STRING);
            if (v == NULL || out.oom) {
                EjBufFree(&out);
                EjFree(v);
                ps->err = "out of memory";
                return NULL;
            }
            /* Adopt the buffer (always NUL-terminated by EjBufReserve). */
            if (out.bytes == NULL) {
                EjBufRaw(&out, "", 0);
            }
            v->u.s.bytes = out.bytes;
            v->u.s.len = out.len;
            return v;
        }
        if (c < 0x20) {
            ps->err = "control character in string";
            break;
        }
        if (c != '\\') {
            EjBufRaw(&out, ps->p, 1);
            ps->p++;
            continue;
        }
        ps->p++;
        if (ps->p >= ps->end) {
            ps->err = "truncated escape";
            break;
        }
        char e = *ps->p++;
        switch (e) {
        case '"':  EjBufRaw(&out, "\"", 1); break;
        case '\\': EjBufRaw(&out, "\\", 1); break;
        case '/':  EjBufRaw(&out, "/", 1); break;
        case 'b':  EjBufRaw(&out, "\b", 1); break;
        case 'f':  EjBufRaw(&out, "\f", 1); break;
        case 'n':  EjBufRaw(&out, "\n", 1); break;
        case 'r':  EjBufRaw(&out, "\r", 1); break;
        case 't':  EjBufRaw(&out, "\t", 1); break;
        case 'u': {
            if (ps->end - ps->p < 4) {
                ps->err = "truncated \\u escape";
                goto fail;
            }
            int h0 = HexVal(ps->p[0]), h1 = HexVal(ps->p[1]);
            int h2 = HexVal(ps->p[2]), h3 = HexVal(ps->p[3]);
            if (h0 < 0 || h1 < 0 || h2 < 0 || h3 < 0) {
                ps->err = "invalid \\u escape";
                goto fail;
            }
            uint32_t cp = (uint32_t)((h0 << 12) | (h1 << 8) | (h2 << 4) | h3);
            ps->p += 4;
            if (cp >= 0xD800 && cp <= 0xDBFF) {
                if (ps->end - ps->p < 6 || ps->p[0] != '\\' ||
                        ps->p[1] != 'u') {
                    ps->err = "unpaired surrogate";
                    goto fail;
                }
                int g0 = HexVal(ps->p[2]), g1 = HexVal(ps->p[3]);
                int g2 = HexVal(ps->p[4]), g3 = HexVal(ps->p[5]);
                if (g0 < 0 || g1 < 0 || g2 < 0 || g3 < 0) {
                    ps->err = "invalid low surrogate";
                    goto fail;
                }
                uint32_t lo = (uint32_t)((g0 << 12) | (g1 << 8) |
                                         (g2 << 4) | g3);
                if (lo < 0xDC00 || lo > 0xDFFF) {
                    ps->err = "unpaired surrogate";
                    goto fail;
                }
                ps->p += 6;
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                ps->err = "unpaired surrogate";
                goto fail;
            }
            Utf8Emit(&out, cp);
            break;
        }
        default:
            ps->err = "invalid escape";
            goto fail;
        }
    }
    if (ps->err == NULL) {
        ps->err = "unterminated string";
    }
fail:
    EjBufFree(&out);
    return NULL;
}

static Ej *
ParseNumber(EjParser *ps)
{
    const char *start = ps->p;
    int isDouble = 0;
    if (ps->p < ps->end && *ps->p == '-') {
        ps->p++;
    }
    if (ps->p >= ps->end || *ps->p < '0' || *ps->p > '9') {
        ps->err = "invalid number";
        return NULL;
    }
    if (*ps->p == '0') {
        ps->p++;
    } else {
        while (ps->p < ps->end && *ps->p >= '0' && *ps->p <= '9') {
            ps->p++;
        }
    }
    if (ps->p < ps->end && *ps->p == '.') {
        isDouble = 1;
        ps->p++;
        if (ps->p >= ps->end || *ps->p < '0' || *ps->p > '9') {
            ps->err = "invalid fraction";
            return NULL;
        }
        while (ps->p < ps->end && *ps->p >= '0' && *ps->p <= '9') {
            ps->p++;
        }
    }
    if (ps->p < ps->end && (*ps->p == 'e' || *ps->p == 'E')) {
        isDouble = 1;
        ps->p++;
        if (ps->p < ps->end && (*ps->p == '+' || *ps->p == '-')) {
            ps->p++;
        }
        if (ps->p >= ps->end || *ps->p < '0' || *ps->p > '9') {
            ps->err = "invalid exponent";
            return NULL;
        }
        while (ps->p < ps->end && *ps->p >= '0' && *ps->p <= '9') {
            ps->p++;
        }
    }
    size_t n = (size_t)(ps->p - start);
    char tmp[340];
    if (n >= sizeof(tmp)) {
        ps->err = "number too long";
        return NULL;
    }
    memcpy(tmp, start, n);
    tmp[n] = '\0';
    if (isDouble) {
        Ej *v = EjNew(EJ_DOUBLE);
        if (v == NULL) {
            ps->err = "out of memory";
            return NULL;
        }
        v->u.d = strtod(tmp, NULL);
        return v;
    }
    errno = 0;
    long long i = strtoll(tmp, NULL, 10);
    if (errno == ERANGE) {
        ps->err = "integer out of 64-bit range";
        return NULL;
    }
    Ej *v = EjNew(EJ_INT);
    if (v == NULL) {
        ps->err = "out of memory";
        return NULL;
    }
    v->u.i = (int64_t)i;
    return v;
}

static Ej *
ParseContainer(EjParser *ps, int isObject)
{
    if (++ps->depth > EJ_MAX_DEPTH) {
        ps->err = "nesting too deep";
        return NULL;
    }
    Ej *cont = EjNew(isObject ? EJ_OBJECT : EJ_ARRAY);
    if (cont == NULL) {
        ps->err = "out of memory";
        return NULL;
    }
    ps->p++;                                   /* opening bracket */
    SkipWs(ps);
    char closer = isObject ? '}' : ']';
    if (ps->p < ps->end && *ps->p == closer) {
        ps->p++;
        ps->depth--;
        return cont;
    }
    for (;;) {
        Ej *key = NULL;
        if (isObject) {
            SkipWs(ps);
            if (ps->p >= ps->end || *ps->p != '"') {
                ps->err = "object key must be a string";
                goto fail;
            }
            key = ParseString(ps);
            if (key == NULL) {
                goto fail;
            }
            SkipWs(ps);
            if (ps->p >= ps->end || *ps->p != ':') {
                ps->err = "expected ':'";
                EjFree(key);
                goto fail;
            }
            ps->p++;
        }
        Ej *item = ParseValue(ps);
        if (item == NULL) {
            EjFree(key);
            goto fail;
        }
        /* Both parts exist; commit them together so EjFree(cont), which
         * walks count entries, can never meet a dangling half-pair. */
        size_t n = cont->u.a.count;
        int committed;
        if (isObject) {
            committed = AppendAt(cont, key, n * 2) &&
                        AppendAt(cont, item, n * 2 + 1);
        } else {
            committed = AppendAt(cont, item, n);
        }
        if (!committed) {
            EjFree(key);
            EjFree(item);
            ps->err = "out of memory";
            goto fail;
        }
        cont->u.a.count++;
        SkipWs(ps);
        if (ps->p < ps->end && *ps->p == ',') {
            ps->p++;
            continue;
        }
        if (ps->p < ps->end && *ps->p == closer) {
            ps->p++;
            ps->depth--;
            return cont;
        }
        ps->err = isObject ? "expected ',' or '}'" : "expected ',' or ']'";
        goto fail;
    }
fail:
    EjFree(cont);
    return NULL;
}

static Ej *
ParseValue(EjParser *ps)
{
    SkipWs(ps);
    if (ps->p >= ps->end) {
        ps->err = "unexpected end of input";
        return NULL;
    }
    switch (*ps->p) {
    case '{': return ParseContainer(ps, 1);
    case '[': return ParseContainer(ps, 0);
    case '"': return ParseString(ps);
    case 't': return Lit(ps, "true")  ? EjNew(EJ_TRUE)  : NULL;
    case 'f': return Lit(ps, "false") ? EjNew(EJ_FALSE) : NULL;
    case 'n': return Lit(ps, "null")  ? EjNew(EJ_NULL)  : NULL;
    default:  return ParseNumber(ps);
    }
}

Ej *
EjParse(const char *buf, size_t len, const char **err)
{
    EjParser ps;
    ps.p = buf;
    ps.end = buf + len;
    ps.err = NULL;
    ps.depth = 0;
    Ej *v = ParseValue(&ps);
    if (v != NULL) {
        SkipWs(&ps);
        if (ps.p != ps.end) {
            EjFree(v);
            v = NULL;
            ps.err = "trailing input";
        }
    }
    if (v == NULL && err != NULL) {
        *err = (ps.err != NULL) ? ps.err : "invalid JSON";
    }
    return v;
}
