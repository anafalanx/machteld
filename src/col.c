/* col.c -- the primitive palette: vectorized column operations for kernels
 * (machteld 0.14.0, docs/engine.md "The col library").
 *
 * Design (plan-machteld-013, panel-reviewed):
 * - This translation unit is compiled with -mavx2; the engine opens `col`
 *   in cells only when the host CPU reports AVX2, and the capability is
 *   declared in hello only from the phase where the full vocabulary
 *   exists. Nothing here runs in the Tcl hosts.
 * - Scalar restrict'd C is the palette's dialect; the compiler's
 *   autovectorization is the default. Hand-AVX2 bodies live under
 *   col._avx2 for the bench lane's paired measurements and earn public
 *   residence only per primitive, by number (P3).
 * - Integer sums are exact int64 by block summation: 4096-element chunks
 *   are provably wraparound-free when every |v| <= 2^50 (4096 * 2^50 <
 *   2^63), proven per chunk by vectorizable min/max; a chunk that breaks
 *   the bound falls back to a per-element __builtin_add_overflow loop.
 *   Detection is deterministic at chunk granularity; the running total
 *   is checked at every chunk boundary. Overflow raises
 *   "col: integer overflow".
 * - Selections are per-state userdata (metered allocator, freed by GC,
 *   no __gc needed), bound to full view identity: the monotone pool
 *   number plus the [a,b) range. A selection is engine furniture and
 *   cannot cross the boundary (the wire refuses userdata as MACHT type).
 */

#include "engine_int.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#undef WIN32_LEAN_AND_MEAN

#include <stdint.h>
#include <string.h>
#include <immintrin.h>

#include "lauxlib.h"

#define COL_SEL_META "machteld.colsel"
#define COL_CHUNK 4096
#define COL_SAFE_BOUND (((int64_t)1) << 50)

typedef struct {
    int poolNum;
    int64_t a, b;                    /* the view range the bits cover */
    uint64_t bits[];
} ColSel;

/* ---------------- argument plumbing ---------------- */

typedef struct {
    int poolNum;
    int64_t a, b;                    /* view range */
    const int64_t *i;                /* 'i' column data (pool-absolute) */
    const double *f;                 /* 'f' column data (pool-absolute) */
    char type;
} ColArg;

static void
ResolveView(lua_State *L, int idx, int *poolNum, int64_t *a, int64_t *b)
{
    if (!EngineViewIdentity(L, idx, poolNum, a, b)) {
        luaL_error(L, "col: argument type (expected a pool view)");
    }
    if (!EnginePoolLive(*poolNum)) {
        luaL_error(L, "col: view outlives its pool");
    }
}

static void
ResolveColumn(lua_State *L, int idx, const char *field, ColArg *out)
{
    ResolveView(L, idx, &out->poolNum, &out->a, &out->b);
    const void *data = NULL;
    int64_t rows = 0;
    if (!EnginePoolColumn(out->poolNum, field, &out->type, &data, &rows)) {
        if (out->type == 0) {
            luaL_error(L, "col: view outlives its pool");
        }
        luaL_error(L, "col: unknown field %s", field);
    }
    if (out->type == 's') {
        luaL_error(L, "col: field %s is not numeric", field);
    }
    out->i = (out->type == 'i') ? (const int64_t *)data : NULL;
    out->f = (out->type == 'f') ? (const double *)data : NULL;
}

static ColSel *
CheckSel(lua_State *L, int idx, const ColArg *col)
{
    ColSel *s = (ColSel *)luaL_checkudata(L, idx, COL_SEL_META);
    if (col != NULL &&
            (s->poolNum != col->poolNum || s->a != col->a ||
             s->b != col->b)) {
        luaL_error(L, "col: selection is bound to another view");
    }
    return s;
}

static ColSel *
NewSel(lua_State *L, int poolNum, int64_t a, int64_t b)
{
    int64_t n = b - a;
    size_t words = (size_t)((n + 63) / 64);
    ColSel *s = (ColSel *)lua_newuserdatauv(L,
        sizeof(ColSel) + words * sizeof(uint64_t), 0);
    s->poolNum = poolNum;
    s->a = a;
    s->b = b;
    memset(s->bits, 0, words * sizeof(uint64_t));
    luaL_setmetatable(L, COL_SEL_META);
    return s;
}

/* ---------------- the scalar reference bodies ----------------
 * These ARE the public primitives in Phase 0 and the normative semantics
 * forever; col._scalar aliases them so the differential lane can always
 * reach them by name. restrict'd plain loops: the compiler's
 * autovectorization (under this TU's -mavx2) is the default dialect. */

enum { OP_LT, OP_LE, OP_GT, OP_GE, OP_EQ, OP_NE, OP_MATCH };

static const char *const kOpNames[] = {
    "lt", "le", "gt", "ge", "eq", "ne", "match", NULL
};

/* The estate's glob dialect: `*` only (`?` and `[]` stay refused by the
 * old macht law). Anchored first segment, anchored last, middles found
 * left to right. Byte-exact, like every string comparison here. */
static int64_t
GlobFind(const char *hay, int64_t hn, const char *needle, int64_t nn)
{
    if (nn == 0) {
        return 0;
    }
    for (int64_t i = 0; i + nn <= hn; i++) {
        if (memcmp(hay + i, needle, (size_t)nn) == 0) {
            return i;
        }
    }
    return -1;
}

static int
GlobMatch(const char *pat, int64_t pn, const char *s, int64_t sn)
{
    int64_t firstStar = -1;
    for (int64_t i = 0; i < pn; i++) {
        if (pat[i] == '*') {
            firstStar = i;
            break;
        }
    }
    if (firstStar < 0) {
        return sn == pn && memcmp(pat, s, (size_t)pn) == 0;
    }
    /* Anchored head. */
    if (sn < firstStar || memcmp(pat, s, (size_t)firstStar) != 0) {
        return 0;
    }
    const char *p = pat + firstStar;
    int64_t pLeft = pn - firstStar;
    const char *h = s + firstStar;
    int64_t hLeft = sn - firstStar;
    /* Middles, then the anchored tail. */
    for (;;) {
        while (pLeft > 0 && *p == '*') {
            p++;
            pLeft--;
        }
        if (pLeft == 0) {
            return 1;                              /* pattern ends in '*' */
        }
        int64_t seg = 0;
        while (seg < pLeft && p[seg] != '*') {
            seg++;
        }
        if (seg == pLeft) {
            /* The last segment: anchored at the end. */
            return hLeft >= seg &&
                   memcmp(h + hLeft - seg, p, (size_t)seg) == 0;
        }
        int64_t at = GlobFind(h, hLeft, p, seg);
        if (at < 0) {
            return 0;
        }
        h += at + seg;
        hLeft -= at + seg;
        p += seg;
        pLeft -= seg;
    }
}

/* One string predicate, evaluated per span. */
static int
StrPred(int op, const char *s, int64_t n, const char *x, int64_t xn)
{
    switch (op) {
    case OP_EQ:    return n == xn && memcmp(s, x, (size_t)n) == 0;
    case OP_NE:    return !(n == xn && memcmp(s, x, (size_t)n) == 0);
    default:       return GlobMatch(x, xn, s, n);  /* OP_MATCH */
    }
}

/* Resolve FIELD when it may be a string column. Returns 'd' (dictionary)
 * or 'p' (span mode) with *sc filled, or 'n' for a numeric field - the
 * caller then takes its numeric path. Dead pools and unknown fields
 * refuse here, under the same names the numeric path uses. */
static char
ResolveStrColumn(lua_State *L, int poolNum, const char *field,
                 EngineStrCol *sc)
{
    char mode = EnginePoolStrColumn(poolNum, field, sc);
    if (mode == 0) {
        luaL_error(L, "col: view outlives its pool");
    }
    if (mode == '?') {
        luaL_error(L, "col: unknown field %s", field);
    }
    return mode;
}

/* The dictionary sweep: one selection bit per row from the matched
 * table, in 64-row word batches, branchless (the branchy per-row form
 * costs ~5 ns/row in mispredictions at mixed selectivity). The
 * single-matched-code case - every eq, and any match that hits one
 * distinct value - collapses to an integer compare over the int32
 * codes, which autovectorizes. matched[] entries are exactly 0 or 1. */
static void
DictSweep(const int32_t *restrict code, int64_t n,
          const uint8_t *restrict matched, int64_t dictN,
          uint64_t *restrict bits)
{
    int64_t hits = 0;
    int32_t only = -1;
    for (int64_t d = 0; d < dictN; d++) {
        if (matched[d]) {
            hits++;
            only = (int32_t)d;
        }
    }
    if (hits == 0) {
        return;                          /* the bits are already zero */
    }
    if (hits == 1) {
        for (int64_t w = 0; w * 64 < n; w++) {
            uint64_t word = 0;
            int64_t base = w * 64;
            int64_t lim = (n - base < 64) ? n - base : 64;
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(code[base + k] == only) << k;
            }
            bits[w] = word;
        }
        return;
    }
    for (int64_t w = 0; w * 64 < n; w++) {
        uint64_t word = 0;
        int64_t base = w * 64;
        int64_t lim = (n - base < 64) ? n - base : 64;
        for (int64_t k = 0; k < lim; k++) {
            word |= (uint64_t)matched[code[base + k]] << k;
        }
        bits[w] = word;
    }
}

/* The string ops' argument X. For match, the pattern is the estate's
 * `*`-only glob dialect; `?` and `[` are refused by name, as the old
 * macht law had it. */
static const char *
CheckStrArg(lua_State *L, int idx, int op, size_t *xnOut)
{
    const char *x = luaL_checklstring(L, idx, xnOut);
    if (op == OP_MATCH &&
            (memchr(x, '?', *xnOut) != NULL ||
             memchr(x, '[', *xnOut) != NULL)) {
        luaL_error(L, "col: match knows only * (? and [ are refused)");
    }
    return x;
}

static void
FilterI64(const int64_t *restrict v, int64_t n, int op, int64_t x,
          uint64_t *restrict bits)
{
    for (int64_t w = 0; w * 64 < n; w++) {
        uint64_t word = 0;
        int64_t base = w * 64;
        int64_t lim = (n - base < 64) ? n - base : 64;
        switch (op) {
        case OP_LT:
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(v[base + k] < x) << k;
            }
            break;
        case OP_LE:
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(v[base + k] <= x) << k;
            }
            break;
        case OP_GT:
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(v[base + k] > x) << k;
            }
            break;
        case OP_GE:
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(v[base + k] >= x) << k;
            }
            break;
        case OP_EQ:
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(v[base + k] == x) << k;
            }
            break;
        default:
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(v[base + k] != x) << k;
            }
        }
        bits[w] = word;
    }
}

/* Block-checked exact sum; returns 0 on overflow (total left undefined).
 * The chunk-safety proof is branch-free and AVX2-native: a value lies in
 * [-B, B) with B = 2^50 exactly when ((uint64_t)v + B) >> 51 == 0, so
 * "every element safe" is an OR-reduction of shifts - vpaddq/vpsrlq/vpor
 * - where a min/max proof would need the 64-bit min/max AVX2 lacks. A
 * safe chunk of 4096 elements sums within +/-2^62, so the unsigned
 * accumulator's wraparound-free cast back to int64 is exact. */
static int
SumI64(const int64_t *restrict v, int64_t n, int64_t *totalOut)
{
    int64_t total = 0;
    for (int64_t at = 0; at < n; at += COL_CHUNK) {
        int64_t lim = (n - at < COL_CHUNK) ? n - at : COL_CHUNK;
        const int64_t *restrict c = v + at;
        uint64_t acc = 0, bad = 0;
        for (int64_t k = 0; k < lim; k++) {
            acc += (uint64_t)c[k];
            bad |= ((uint64_t)c[k] + (uint64_t)COL_SAFE_BOUND) >> 51;
        }
        if (bad == 0) {
            if (__builtin_add_overflow(total, (int64_t)acc, &total)) {
                return 0;
            }
        } else {
            /* The rare wild chunk: exact per-element, order-preserving. */
            int64_t chunk = 0;
            for (int64_t k = 0; k < lim; k++) {
                if (__builtin_add_overflow(chunk, c[k], &chunk)) {
                    return 0;
                }
            }
            if (__builtin_add_overflow(total, chunk, &total)) {
                return 0;
            }
        }
    }
    *totalOut = total;
    return 1;
}

static int
SumUnderI64(const int64_t *restrict v, int64_t n, const uint64_t *bits,
            int64_t *totalOut)
{
    int64_t total = 0;
    for (int64_t w = 0; w * 64 < n; w++) {
        uint64_t word = bits[w];
        while (word != 0) {
            int k = __builtin_ctzll(word);
            word &= word - 1;
            if (__builtin_add_overflow(total, v[w * 64 + k], &total)) {
                return 0;
            }
        }
    }
    *totalOut = total;
    return 1;
}

/* The fused predicate-reduction (the P2 miss's lesson): one pass, no
 * bitmap. Masked accumulation keeps the loop vectorizable - the mask is
 * arithmetic (0 or all-ones), the accumulate and the safety proof are
 * AND-gated by it - and the same chunk/wild-fallback structure keeps
 * overflow detection deterministic. Admitted 2026-08-23 by owner ruling
 * on the P2 stop-and-decide. */
#define COL_SUMWHERE_CHUNK(CMP)                                            \
    for (int64_t k = 0; k < lim; k++) {                                    \
        uint64_t m = (uint64_t)0 - (uint64_t)(pp[k] CMP x);                 \
        acc += m & (uint64_t)vv[k];                                         \
        bad |= m & (((uint64_t)vv[k] + (uint64_t)COL_SAFE_BOUND) >> 51);    \
    }

static int
SumWhereI64(const int64_t *restrict v, const int64_t *restrict p,
            int64_t n, int op, int64_t x, int64_t *totalOut)
{
    int64_t total = 0;
    for (int64_t at = 0; at < n; at += COL_CHUNK) {
        int64_t lim = (n - at < COL_CHUNK) ? n - at : COL_CHUNK;
        const int64_t *restrict vv = v + at;
        const int64_t *restrict pp = p + at;
        uint64_t acc = 0, bad = 0;
        switch (op) {
        case OP_LT: COL_SUMWHERE_CHUNK(<)  break;
        case OP_LE: COL_SUMWHERE_CHUNK(<=) break;
        case OP_GT: COL_SUMWHERE_CHUNK(>)  break;
        case OP_GE: COL_SUMWHERE_CHUNK(>=) break;
        case OP_EQ: COL_SUMWHERE_CHUNK(==) break;
        default:    COL_SUMWHERE_CHUNK(!=) break;
        }
        if (bad == 0) {
            if (__builtin_add_overflow(total, (int64_t)acc, &total)) {
                return 0;
            }
        } else {
            /* The rare wild chunk: exact per-element on selected rows. */
            int64_t chunk = 0;
            for (int64_t k = 0; k < lim; k++) {
                int hit;
                switch (op) {
                case OP_LT: hit = pp[k] < x; break;
                case OP_LE: hit = pp[k] <= x; break;
                case OP_GT: hit = pp[k] > x; break;
                case OP_GE: hit = pp[k] >= x; break;
                case OP_EQ: hit = pp[k] == x; break;
                default:    hit = pp[k] != x;
                }
                if (hit && __builtin_add_overflow(chunk, vv[k], &chunk)) {
                    return 0;
                }
            }
            if (__builtin_add_overflow(total, chunk, &total)) {
                return 0;
            }
        }
    }
    *totalOut = total;
    return 1;
}

/* ---------------- the float and matrix bodies (Phase 1) ----------------
 * Normative laws, written here and mirrored in the contract page:
 * - Float comparisons are IEEE: NaN matches nothing except ne (and a NaN
 *   probe value matches nothing except ne, which then matches every row).
 * - Float sums use the row-striped eight-lane tree: lane k&7 accumulates
 *   row k (a masked-out row contributes +0.0), lanes fold left to right,
 *   chunk order is row order. Deterministic by construction; NaN rows
 *   that are selected propagate.
 * - min/max skip NaN, seed at the first surviving element, compare by
 *   plain < / >; nothing surviving raises "col: empty selection". */

static void
FilterF64(const double *restrict v, int64_t n, int op, double x,
          uint64_t *restrict bits)
{
    for (int64_t w = 0; w * 64 < n; w++) {
        uint64_t word = 0;
        int64_t base = w * 64;
        int64_t lim = (n - base < 64) ? n - base : 64;
        switch (op) {
        case OP_LT:
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(v[base + k] < x) << k;
            }
            break;
        case OP_LE:
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(v[base + k] <= x) << k;
            }
            break;
        case OP_GT:
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(v[base + k] > x) << k;
            }
            break;
        case OP_GE:
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(v[base + k] >= x) << k;
            }
            break;
        case OP_EQ:
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(v[base + k] == x) << k;
            }
            break;
        default:
            for (int64_t k = 0; k < lim; k++) {
                word |= (uint64_t)(v[base + k] != x) << k;
            }
        }
        bits[w] = word;
    }
}

static double
SumF64Masked(const double *restrict v, int64_t n, const uint64_t *bits)
{
    double acc[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
    for (int64_t k = 0; k < n; k++) {
        int sel = (bits == NULL) || ((bits[k >> 6] >> (k & 63)) & 1u);
        acc[k & 7] += sel ? v[k] : 0.0;
    }
    return ((acc[0] + acc[1]) + (acc[2] + acc[3])) +
           ((acc[4] + acc[5]) + (acc[6] + acc[7]));
}

static int
MinMaxI64(const int64_t *restrict v, int64_t n, const uint64_t *bits,
          int isMax, int64_t *out)
{
    int found = 0;
    int64_t best = 0;
    for (int64_t k = 0; k < n; k++) {
        if (bits != NULL && !((bits[k >> 6] >> (k & 63)) & 1u)) {
            continue;
        }
        if (!found || (isMax ? v[k] > best : v[k] < best)) {
            best = v[k];
            found = 1;
        }
    }
    *out = best;
    return found;
}

static int
MinMaxF64(const double *restrict v, int64_t n, const uint64_t *bits,
          int isMax, double *out)
{
    int found = 0;
    double best = 0;
    for (int64_t k = 0; k < n; k++) {
        if (bits != NULL && !((bits[k >> 6] >> (k & 63)) & 1u)) {
            continue;
        }
        if (v[k] != v[k]) {
            continue;                              /* NaN is skipped */
        }
        if (!found || (isMax ? v[k] > best : v[k] < best)) {
            best = v[k];
            found = 1;
        }
    }
    *out = best;
    return found;
}

/* The fused matrix: value {i,f} x predicate {i,f}, all six ops. Integer
 * values keep the exact chunked path; float values use the striped tree
 * with the predicate as the mask. */
#define COL_SUMWHERE_FP_CHUNK(PT, CMP)                                     \
    for (int64_t k = 0; k < lim; k++) {                                    \
        uint64_t m = (uint64_t)0 - (uint64_t)(((const PT *)pp)[k] CMP x);  \
        acc += m & (uint64_t)vv[k];                                        \
        bad |= m & (((uint64_t)vv[k] + (uint64_t)COL_SAFE_BOUND) >> 51);   \
    }

static int
SumWhereI64Fp(const int64_t *restrict v, const double *restrict pd,
              int64_t n, int op, double x, int64_t *totalOut)
{
    int64_t total = 0;
    for (int64_t at = 0; at < n; at += COL_CHUNK) {
        int64_t lim = (n - at < COL_CHUNK) ? n - at : COL_CHUNK;
        const int64_t *restrict vv = v + at;
        const double *restrict pp = pd + at;
        uint64_t acc = 0, bad = 0;
        switch (op) {
        case OP_LT: COL_SUMWHERE_FP_CHUNK(double, <)  break;
        case OP_LE: COL_SUMWHERE_FP_CHUNK(double, <=) break;
        case OP_GT: COL_SUMWHERE_FP_CHUNK(double, >)  break;
        case OP_GE: COL_SUMWHERE_FP_CHUNK(double, >=) break;
        case OP_EQ: COL_SUMWHERE_FP_CHUNK(double, ==) break;
        default:    COL_SUMWHERE_FP_CHUNK(double, !=) break;
        }
        if (bad == 0) {
            if (__builtin_add_overflow(total, (int64_t)acc, &total)) {
                return 0;
            }
        } else {
            int64_t chunk = 0;
            for (int64_t k = 0; k < lim; k++) {
                int hit;
                switch (op) {
                case OP_LT: hit = pp[k] < x; break;
                case OP_LE: hit = pp[k] <= x; break;
                case OP_GT: hit = pp[k] > x; break;
                case OP_GE: hit = pp[k] >= x; break;
                case OP_EQ: hit = pp[k] == x; break;
                default:    hit = pp[k] != x;
                }
                if (hit && __builtin_add_overflow(chunk, vv[k], &chunk)) {
                    return 0;
                }
            }
            if (__builtin_add_overflow(total, chunk, &total)) {
                return 0;
            }
        }
    }
    *totalOut = total;
    return 1;
}

#define COL_SUMWHERE_F_BODY(PT, CMP)                                       \
    for (int64_t k = 0; k < n; k++) {                                      \
        int sel = ((const PT *)p)[k] CMP x;                                \
        acc[k & 7] += sel ? v[k] : 0.0;                                    \
    }

#define COL_SUMWHERE_F_ALL(PT, XT)                                         \
    double acc[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };                            \
    XT x = xIn;                                                            \
    switch (op) {                                                          \
    case OP_LT: COL_SUMWHERE_F_BODY(PT, <)  break;                         \
    case OP_LE: COL_SUMWHERE_F_BODY(PT, <=) break;                         \
    case OP_GT: COL_SUMWHERE_F_BODY(PT, >)  break;                         \
    case OP_GE: COL_SUMWHERE_F_BODY(PT, >=) break;                         \
    case OP_EQ: COL_SUMWHERE_F_BODY(PT, ==) break;                         \
    default:    COL_SUMWHERE_F_BODY(PT, !=) break;                         \
    }                                                                      \
    return ((acc[0] + acc[1]) + (acc[2] + acc[3])) +                       \
           ((acc[4] + acc[5]) + (acc[6] + acc[7]))

static double
SumWhereF64Ip(const double *restrict v, const void *restrict p,
              int64_t n, int op, int64_t xIn)
{
    COL_SUMWHERE_F_ALL(int64_t, int64_t);
}

static double
SumWhereF64Fp(const double *restrict v, const void *restrict p,
              int64_t n, int op, double xIn)
{
    COL_SUMWHERE_F_ALL(double, double);
}

static int64_t
CountBits(const uint64_t *bits, int64_t n)
{
    int64_t total = 0;
    for (int64_t w = 0; w * 64 < n; w++) {
        total += __builtin_popcountll(bits[w]);
    }
    return total;
}

/* ---------------- hand-AVX2 bodies (bench lane only, P3) ----------------
 * Each implements the SAME chunk/bound structure as its scalar twin, so
 * the differential lane's exact-match promise holds by construction. */

static void
FilterI64Avx2(const int64_t *restrict v, int64_t n, int op, int64_t x,
              uint64_t *restrict bits)
{
    __m256i vx = _mm256_set1_epi64x(x);
    for (int64_t w = 0; w * 64 < n; w++) {
        uint64_t word = 0;
        int64_t base = w * 64;
        int64_t lim = (n - base < 64) ? n - base : 64;
        int64_t k = 0;
        for (; k + 4 <= lim; k += 4) {
            __m256i vv = _mm256_loadu_si256(
                (const __m256i *)(const void *)(v + base + k));
            __m256i m;
            switch (op) {
            case OP_LT: m = _mm256_cmpgt_epi64(vx, vv); break;
            case OP_GT: m = _mm256_cmpgt_epi64(vv, vx); break;
            case OP_EQ: m = _mm256_cmpeq_epi64(vv, vx); break;
            case OP_NE:
                m = _mm256_xor_si256(_mm256_cmpeq_epi64(vv, vx),
                                     _mm256_set1_epi64x(-1));
                break;
            case OP_LE:
                m = _mm256_xor_si256(_mm256_cmpgt_epi64(vv, vx),
                                     _mm256_set1_epi64x(-1));
                break;
            default: /* OP_GE */
                m = _mm256_xor_si256(_mm256_cmpgt_epi64(vx, vv),
                                     _mm256_set1_epi64x(-1));
            }
            unsigned lanes = (unsigned)_mm256_movemask_pd(
                _mm256_castsi256_pd(m));
            word |= (uint64_t)lanes << k;
        }
        for (; k < lim; k++) {
            int hit;
            switch (op) {
            case OP_LT: hit = v[base + k] < x; break;
            case OP_LE: hit = v[base + k] <= x; break;
            case OP_GT: hit = v[base + k] > x; break;
            case OP_GE: hit = v[base + k] >= x; break;
            case OP_EQ: hit = v[base + k] == x; break;
            default:    hit = v[base + k] != x;
            }
            word |= (uint64_t)hit << k;
        }
        bits[w] = word;
    }
}

static int
SumI64Avx2(const int64_t *restrict v, int64_t n, int64_t *totalOut)
{
    __m256i vbound = _mm256_set1_epi64x(COL_SAFE_BOUND);
    int64_t total = 0;
    for (int64_t at = 0; at < n; at += COL_CHUNK) {
        int64_t lim = (n - at < COL_CHUNK) ? n - at : COL_CHUNK;
        const int64_t *restrict c = v + at;
        __m256i vacc = _mm256_setzero_si256();
        __m256i vbad = _mm256_setzero_si256();
        int64_t k = 0;
        for (; k + 4 <= lim; k += 4) {
            __m256i vv = _mm256_loadu_si256(
                (const __m256i *)(const void *)(c + k));
            vacc = _mm256_add_epi64(vacc, vv);
            vbad = _mm256_or_si256(vbad,
                _mm256_srli_epi64(_mm256_add_epi64(vv, vbound), 51));
        }
        int64_t lanes[4], lbad[4];
        _mm256_storeu_si256((__m256i *)(void *)lanes, vacc);
        _mm256_storeu_si256((__m256i *)(void *)lbad, vbad);
        uint64_t acc = (uint64_t)lanes[0] + (uint64_t)lanes[1] +
                       (uint64_t)lanes[2] + (uint64_t)lanes[3];
        uint64_t bad = (uint64_t)lbad[0] | (uint64_t)lbad[1] |
                       (uint64_t)lbad[2] | (uint64_t)lbad[3];
        for (; k < lim; k++) {
            acc += (uint64_t)c[k];
            bad |= ((uint64_t)c[k] + (uint64_t)COL_SAFE_BOUND) >> 51;
        }
        if (bad == 0) {
            if (__builtin_add_overflow(total, (int64_t)acc, &total)) {
                return 0;
            }
        } else {
            int64_t chunk = 0;
            for (int64_t j = 0; j < lim; j++) {
                if (__builtin_add_overflow(chunk, c[j], &chunk)) {
                    return 0;
                }
            }
            if (__builtin_add_overflow(total, chunk, &total)) {
                return 0;
            }
        }
    }
    *totalOut = total;
    return 1;
}

/* ---------------- Lua faces ---------------- */

typedef struct {
    void (*filter)(const int64_t *restrict, int64_t, int, int64_t,
                   uint64_t *restrict);
    int (*sum)(const int64_t *restrict, int64_t, int64_t *);
} ColImpl;

static const ColImpl kScalar = { FilterI64, SumI64 };
static const ColImpl kAvx2 = { FilterI64Avx2, SumI64Avx2 };

static int
LFilter(lua_State *L)
{
    const ColImpl *impl = (const ColImpl *)lua_touserdata(L,
        lua_upvalueindex(1));
    ColArg col;
    const char *field = luaL_checkstring(L, 2);
    int op = luaL_checkoption(L, 3, NULL, kOpNames);
    int poolNum;
    int64_t a, b;
    ResolveView(L, 1, &poolNum, &a, &b);
    EngineStrCol sc;
    char mode = ResolveStrColumn(L, poolNum, field, &sc);
    if (mode != 'n') {
        /* String column: eq/ne/match only, byte-exact. */
        if (op != OP_EQ && op != OP_NE && op != OP_MATCH) {
            return luaL_error(L, "col: op %s needs a numeric field",
                              kOpNames[op]);
        }
        size_t xn;
        const char *x = CheckStrArg(L, 4, op, &xn);
        if (mode == 'd') {
            /* The dictionary win: the predicate runs once per DISTINCT
             * value; the rows are an integer sweep. The matched table is
             * metered userdata so an error path leaks nothing. */
            uint8_t *matched = (uint8_t *)lua_newuserdatauv(L,
                (size_t)sc.dictN, 0);
            for (int64_t d = 0; d < sc.dictN; d++) {
                matched[d] = (uint8_t)StrPred(op,
                    sc.arena + sc.dictOff[d], sc.dictLen[d],
                    x, (int64_t)xn);
            }
            ColSel *sel = NewSel(L, poolNum, a, b);
            DictSweep(sc.code + a, b - a, matched, sc.dictN, sel->bits);
        } else {
            /* Span mode, past the cardinality escape: per row. */
            ColSel *sel = NewSel(L, poolNum, a, b);
            for (int64_t i = 0; i < b - a; i++) {
                if (StrPred(op, sc.arena + sc.off[a + i], sc.len[a + i],
                            x, (int64_t)xn)) {
                    sel->bits[i >> 6] |= (uint64_t)1 << (i & 63);
                }
            }
        }
        return 1;                    /* the selection is on top */
    }
    if (op == OP_MATCH) {
        return luaL_error(L, "col: match needs a string field");
    }
    ResolveColumn(L, 1, field, &col);
    ColSel *s;
    if (col.type == 'f') {
        double x = (double)luaL_checknumber(L, 4);
        s = NewSel(L, col.poolNum, col.a, col.b);
        FilterF64(col.f + col.a, col.b - col.a, op, x, s->bits);
    } else {
        int64_t x = (int64_t)luaL_checkinteger(L, 4);
        s = NewSel(L, col.poolNum, col.a, col.b);
        impl->filter(col.i + col.a, col.b - col.a, op, x, s->bits);
    }
    (void)s;
    return 1;
}

static int
LSum(lua_State *L)
{
    const ColImpl *impl = (const ColImpl *)lua_touserdata(L,
        lua_upvalueindex(1));
    ColArg col;
    const char *field = luaL_checkstring(L, 2);
    ResolveColumn(L, 1, field, &col);
    const uint64_t *bits = NULL;
    if (lua_gettop(L) >= 3 && !lua_isnil(L, 3)) {
        bits = CheckSel(L, 3, &col)->bits;
    }
    if (col.type == 'f') {
        lua_pushnumber(L, (lua_Number)SumF64Masked(col.f + col.a,
            col.b - col.a, bits));
        return 1;
    }
    int64_t total = 0;
    int ok;
    if (bits != NULL) {
        ok = SumUnderI64(col.i + col.a, col.b - col.a, bits, &total);
    } else {
        ok = impl->sum(col.i + col.a, col.b - col.a, &total);
    }
    if (!ok) {
        return luaL_error(L, "col: integer overflow");
    }
    lua_pushinteger(L, (lua_Integer)total);
    return 1;
}

static int
LMinMax(lua_State *L)
{
    int isMax = (int)lua_tointeger(L, lua_upvalueindex(1));
    ColArg col;
    const char *field = luaL_checkstring(L, 2);
    ResolveColumn(L, 1, field, &col);
    const uint64_t *bits = NULL;
    if (lua_gettop(L) >= 3 && !lua_isnil(L, 3)) {
        bits = CheckSel(L, 3, &col)->bits;
    }
    if (col.type == 'f') {
        double out = 0;
        if (!MinMaxF64(col.f + col.a, col.b - col.a, bits, isMax, &out)) {
            return luaL_error(L, "col: empty selection");
        }
        lua_pushnumber(L, (lua_Number)out);
        return 1;
    }
    int64_t out = 0;
    if (!MinMaxI64(col.i + col.a, col.b - col.a, bits, isMax, &out)) {
        return luaL_error(L, "col: empty selection");
    }
    lua_pushinteger(L, (lua_Integer)out);
    return 1;
}

static int
LBand(lua_State *L)
{
    ColSel *a = (ColSel *)luaL_checkudata(L, 1, COL_SEL_META);
    ColSel *b = (ColSel *)luaL_checkudata(L, 2, COL_SEL_META);
    int orMode = (int)lua_tointeger(L, lua_upvalueindex(1));
    if (a->poolNum != b->poolNum || a->a != b->a || a->b != b->b) {
        return luaL_error(L, "col: selection is bound to another view");
    }
    ColSel *r = NewSel(L, a->poolNum, a->a, a->b);
    int64_t words = ((a->b - a->a) + 63) / 64;
    for (int64_t w = 0; w < words; w++) {
        r->bits[w] = orMode ? (a->bits[w] | b->bits[w])
                            : (a->bits[w] & b->bits[w]);
    }
    return 1;
}

static int
LBnot(lua_State *L)
{
    ColSel *a = (ColSel *)luaL_checkudata(L, 1, COL_SEL_META);
    ColSel *r = NewSel(L, a->poolNum, a->a, a->b);
    int64_t n = a->b - a->a;
    int64_t words = (n + 63) / 64;
    for (int64_t w = 0; w < words; w++) {
        r->bits[w] = ~a->bits[w];
    }
    if ((n & 63) != 0) {
        /* Bits beyond the view's rows stay zero, always. */
        r->bits[words - 1] &= (((uint64_t)1 << (n & 63)) - 1);
    }
    return 1;
}

/* col.sumwhere(h, FIELD, BYFIELD, OP, X): sum FIELD over the rows where
 * BYFIELD OP X - the one-pass fused form, scalar-only by P3's verdict;
 * its differential twin is the composed filter+sum, which must agree
 * exactly (both are exact int64). */
static int
LSumWhere(lua_State *L)
{
    ColArg vcol, pcol;
    const char *field = luaL_checkstring(L, 2);
    const char *byfield = luaL_checkstring(L, 3);
    int op = luaL_checkoption(L, 4, NULL, kOpNames);
    ResolveColumn(L, 1, field, &vcol);
    EngineStrCol sc;
    char pmode = ResolveStrColumn(L, vcol.poolNum, byfield, &sc);
    if (pmode != 'n') {
        /* String predicate arm: "sum bytes where the path matches the
         * api prefix" in one pass. eq/ne/match only; sequential
         * accumulation order - the differential twin is the plain Lua
         * loop. */
        if (op != OP_EQ && op != OP_NE && op != OP_MATCH) {
            return luaL_error(L, "col: op %s needs a numeric field",
                              kOpNames[op]);
        }
        size_t xn;
        const char *x = CheckStrArg(L, 5, op, &xn);
        int64_t sn = vcol.b - vcol.a;
        uint8_t *matched = NULL;
        if (pmode == 'd') {
            matched = (uint8_t *)lua_newuserdatauv(L, (size_t)sc.dictN, 0);
            for (int64_t d = 0; d < sc.dictN; d++) {
                matched[d] = (uint8_t)StrPred(op,
                    sc.arena + sc.dictOff[d], sc.dictLen[d],
                    x, (int64_t)xn);
            }
        }
        if (vcol.type == 'f') {
            double t = 0;
            for (int64_t i = 0; i < sn; i++) {
                int hit = (matched != NULL)
                    ? matched[sc.code[vcol.a + i]]
                    : StrPred(op, sc.arena + sc.off[vcol.a + i],
                              sc.len[vcol.a + i], x, (int64_t)xn);
                if (hit) {
                    t += vcol.f[vcol.a + i];
                }
            }
            lua_pushnumber(L, (lua_Number)t);
            return 1;
        }
        int64_t t = 0;
        for (int64_t i = 0; i < sn; i++) {
            int hit = (matched != NULL)
                ? matched[sc.code[vcol.a + i]]
                : StrPred(op, sc.arena + sc.off[vcol.a + i],
                          sc.len[vcol.a + i], x, (int64_t)xn);
            if (hit && __builtin_add_overflow(t, vcol.i[vcol.a + i], &t)) {
                return luaL_error(L, "col: integer overflow");
            }
        }
        lua_pushinteger(L, (lua_Integer)t);
        return 1;
    }
    if (op == OP_MATCH) {
        return luaL_error(L, "col: match needs a string field");
    }
    ResolveColumn(L, 1, byfield, &pcol);
    int64_t n = vcol.b - vcol.a;
    if (vcol.type == 'f') {
        double out;
        if (pcol.type == 'f') {
            out = SumWhereF64Fp(vcol.f + vcol.a, pcol.f + pcol.a, n, op,
                                (double)luaL_checknumber(L, 5));
        } else {
            out = SumWhereF64Ip(vcol.f + vcol.a, pcol.i + pcol.a, n, op,
                                (int64_t)luaL_checkinteger(L, 5));
        }
        lua_pushnumber(L, (lua_Number)out);
        return 1;
    }
    int64_t total = 0;
    int ok;
    if (pcol.type == 'f') {
        ok = SumWhereI64Fp(vcol.i + vcol.a, pcol.f + pcol.a, n, op,
                           (double)luaL_checknumber(L, 5), &total);
    } else {
        ok = SumWhereI64(vcol.i + vcol.a, pcol.i + pcol.a, n, op,
                         (int64_t)luaL_checkinteger(L, 5), &total);
    }
    if (!ok) {
        return luaL_error(L, "col: integer overflow");
    }
    lua_pushinteger(L, (lua_Integer)total);
    return 1;
}

/* col.rows(h, SEL_or_nil, FIRST, COUNT) - the bounded row-slice fetch
 * (plan-machteld-014, the GUI spike): rows of the view in row order, or
 * the FIRST-th..(FIRST+COUNT-1)-th SELECTED rows under SEL, as a
 * sequence of row sequences in pool column order. FIRST is 1-based;
 * FIRST past the population yields an empty sequence (a scrolled-past
 * page is an empty page, not an error); COUNT above 4096 refuses by
 * name. Reads pool memory directly - dictionary or span alike - so it
 * works where materializing h.FIELD cannot. */
typedef struct {
    char type;                       /* 'i', 'f', or 's' */
    const int64_t *i;
    const double *f;
    EngineStrCol sc;
} RowsCol;

/* Resolve every column of a live pool once, in pool order. Returns the
 * column count. Shared by col.rows and col.topn. */
static int
ResolveRowsCols(int poolNum, RowsCol *cols)
{
    const char *names[64];
    int ncols = 0;
    char t;
    while (ncols < 64 && EnginePoolField(poolNum, ncols, &names[ncols], &t)) {
        RowsCol *rc = &cols[ncols];
        rc->type = t;
        rc->i = NULL;
        rc->f = NULL;
        if (t == 's') {
            EnginePoolStrColumn(poolNum, names[ncols], &rc->sc);
        } else {
            const void *data = NULL;
            int64_t rows = 0;
            char tt;
            EnginePoolColumn(poolNum, names[ncols], &tt, &data, &rows);
            rc->i = (t == 'i') ? (const int64_t *)data : NULL;
            rc->f = (t == 'f') ? (const double *)data : NULL;
        }
        ncols++;
    }
    return ncols;
}

/* Push one pool row as a sequence in pool column order. */
static void
PushRowSeq(lua_State *L, const RowsCol *cols, int ncols, int64_t row)
{
    lua_createtable(L, ncols, 0);
    for (int c = 0; c < ncols; c++) {
        const RowsCol *rc = &cols[c];
        switch (rc->type) {
        case 'i':
            lua_pushinteger(L, (lua_Integer)rc->i[row]);
            break;
        case 'f':
            lua_pushnumber(L, (lua_Number)rc->f[row]);
            break;
        default:
            if (rc->sc.dictN > 0) {
                int32_t dc = rc->sc.code[row];
                lua_pushlstring(L, rc->sc.arena + rc->sc.dictOff[dc],
                                (size_t)rc->sc.dictLen[dc]);
            } else {
                lua_pushlstring(L, rc->sc.arena + rc->sc.off[row],
                                (size_t)rc->sc.len[row]);
            }
        }
        lua_rawseti(L, -2, (lua_Integer)(c + 1));
    }
}

static int
LRows(lua_State *L)
{
    int poolNum;
    int64_t a, b;
    ResolveView(L, 1, &poolNum, &a, &b);
    ColSel *sel = NULL;
    if (!lua_isnoneornil(L, 2)) {
        ColSel *s = (ColSel *)luaL_checkudata(L, 2, COL_SEL_META);
        if (s->poolNum != poolNum || s->a != a || s->b != b) {
            return luaL_error(L, "col: selection is bound to another view");
        }
        sel = s;
    }
    int64_t first = (int64_t)luaL_checkinteger(L, 3);
    int64_t count = (int64_t)luaL_checkinteger(L, 4);
    if (first < 1 || count < 0) {
        return luaL_error(L, "col: argument type (FIRST >= 1, COUNT >= 0)");
    }
    if (count > 4096) {
        return luaL_error(L, "col: rows asks more than 4096");
    }
    RowsCol cols[64];
    int ncols = ResolveRowsCols(poolNum, cols);
    /* Collect the view-relative row indices of the page. */
    int64_t n = b - a;
    int64_t *page = (int64_t *)lua_newuserdatauv(L,
        (size_t)(count > 0 ? count : 1) * sizeof(int64_t), 0);
    int64_t got = 0;
    if (sel == NULL) {
        for (int64_t i = first - 1; i < n && got < count; i++) {
            page[got++] = i;
        }
    } else {
        int64_t words = (n + 63) / 64;
        int64_t seen = 0;
        for (int64_t wi = 0; wi < words && got < count; wi++) {
            uint64_t w = sel->bits[wi];
            if (w == 0) {
                continue;
            }
            int pc = __builtin_popcountll(w);
            if (seen + pc < first) {
                seen += pc;               /* the whole word is before us */
                continue;
            }
            while (w != 0 && got < count) {
                int tz = __builtin_ctzll(w);
                w &= w - 1;
                seen++;
                if (seen >= first) {
                    page[got++] = wi * 64 + tz;
                }
            }
        }
    }
    /* Build the page: a sequence of row sequences. */
    lua_createtable(L, (int)got, 0);
    for (int64_t r = 0; r < got; r++) {
        PushRowSeq(L, cols, ncols, a + page[r]);
        lua_rawseti(L, -2, (lua_Integer)(r + 1));
    }
    return 1;
}

/* col.groupcount(h, BYFIELD ?, SEL?) and col.groupsum(h, FIELD,
 * BYFIELD ?, SEL?) - the chart verbs (plan-machteld-014, the
 * follow-through). BYFIELD is a dictionary-mode s column (the codes ARE
 * the group indices: one integer sweep, k accumulators) or an i column
 * (bounded open-addressed hash, first-appearance numbering, past
 * COL_GROUP_LIMIT groups refuses by name). The panel's pins: the i
 * group universe is the VIEW's rows with SEL ignored - the key set and
 * its order never depend on the selection, SEL masks only the counting
 * (dict partials from shards align by index, i partials by KEY only);
 * a zero-row s column answers empty, never the dictionary-limit
 * refusal. Returns {keys, counts} / {keys, counts, sums}, parallel
 * sequences in first-appearance order, every group included. Integer
 * sums are per-element checked (groups break the chunk proof); float
 * sums accumulate sequentially per group - the twin is the Lua loop. */
#define COL_GROUP_LIMIT 65536

static int
LGroup(lua_State *L)
{
    int wantSum = (int)lua_tointeger(L, lua_upvalueindex(1));
    int byIdx = wantSum ? 3 : 2;
    int poolNum;
    int64_t a, b;
    ResolveView(L, 1, &poolNum, &a, &b);
    ColArg vcol;
    if (wantSum) {
        ResolveColumn(L, 1, luaL_checkstring(L, 2), &vcol);
    }
    const char *byfield = luaL_checkstring(L, byIdx);
    const uint64_t *bits = NULL;
    if (!lua_isnoneornil(L, byIdx + 1)) {
        ColSel *s = (ColSel *)luaL_checkudata(L, byIdx + 1, COL_SEL_META);
        if (s->poolNum != poolNum || s->a != a || s->b != b) {
            return luaL_error(L, "col: selection is bound to another view");
        }
        bits = s->bits;
    }
    int64_t n = b - a;
    EngineStrCol sc;
    char bmode = ResolveStrColumn(L, poolNum, byfield, &sc);
    int64_t k = 0;                   /* the group count */
    int64_t *ikeys = NULL;           /* the i arm's keys */
    if (bmode == 'd') {
        k = sc.dictN;
    } else if (bmode == 'p') {
        if (sc.rows != 0) {
            return luaL_error(L,
                "col: field %s is past the dictionary limit (span mode)",
                byfield);
        }
        /* zero rows: an empty answer, never a lying refusal */
    } else {
        /* Numeric BYFIELD: i groups by value, f refuses. */
        ColArg bcol;
        ResolveColumn(L, 1, byfield, &bcol);
        if (bcol.type != 'i') {
            return luaL_error(L, "col: cannot group by a float field");
        }
        bmode = 'i';
    }
    /* The accumulators (metered): dict arm sizes by the dictionary;
     * the i arm sizes at the group limit up front - its k grows as
     * keys appear (fused single pass: the first O2 run's separate
     * gidx round-trip cost 25M x 4 bytes of traffic for nothing). */
    int64_t acap = (bmode == 'i') ? COL_GROUP_LIMIT : (k > 0 ? k : 1);
    int64_t *cnt = (int64_t *)lua_newuserdatauv(L,
        (size_t)acap * sizeof(int64_t), 0);
    memset(cnt, 0, (size_t)acap * sizeof(int64_t));
    int64_t *sumi = NULL;
    double *sumf = NULL;
    if (wantSum) {
        if (vcol.type == 'i') {
            sumi = (int64_t *)lua_newuserdatauv(L,
                (size_t)acap * sizeof(int64_t), 0);
            memset(sumi, 0, (size_t)acap * sizeof(int64_t));
        } else {
            sumf = (double *)lua_newuserdatauv(L,
                (size_t)acap * sizeof(double), 0);
            memset(sumf, 0, (size_t)acap * sizeof(double));
        }
    }
    if (bmode == 'i') {
        /* The i arm, fused: the group universe is the VIEW's rows with
         * SEL ignored - every key is inserted, the selection masks
         * only the counting. One pass, no per-row index buffer. */
        ColArg bcol;
        ResolveColumn(L, 1, byfield, &bcol);
        size_t htSize = 4;
        while (htSize < (size_t)COL_GROUP_LIMIT * 4) {
            htSize <<= 1;
        }
        int32_t *ht = (int32_t *)lua_newuserdatauv(L,
            htSize * sizeof(int32_t), 0);
        memset(ht, 0xFF, htSize * sizeof(int32_t));
        ikeys = (int64_t *)lua_newuserdatauv(L,
            (size_t)COL_GROUP_LIMIT * sizeof(int64_t), 0);
        for (int64_t i = 0; i < n; i++) {
            int64_t key = bcol.i[a + i];
            uint64_t h = (uint64_t)key * 11400714819323198485ull;
            size_t slot = (size_t)(h >> 32) & (htSize - 1);
            int32_t g;
            for (;;) {
                int32_t idx = ht[slot];
                if (idx < 0) {
                    if (k == COL_GROUP_LIMIT) {
                        return luaL_error(L,
                            "col: more than 65536 groups");
                    }
                    ht[slot] = (int32_t)k;
                    ikeys[k] = key;
                    g = (int32_t)k;
                    k++;
                    break;
                }
                if (ikeys[idx] == key) {
                    g = idx;
                    break;
                }
                slot = (slot + 1) & (htSize - 1);
            }
            if (bits != NULL &&
                    (bits[i >> 6] & ((uint64_t)1 << (i & 63))) == 0) {
                continue;
            }
            cnt[g]++;
            if (sumi != NULL) {
                if (__builtin_add_overflow(sumi[g], vcol.i[a + i],
                                           &sumi[g])) {
                    return luaL_error(L, "col: integer overflow");
                }
            } else if (sumf != NULL) {
                sumf[g] += vcol.f[a + i];
            }
        }
    } else {
        for (int64_t i = 0; i < n; i++) {
            if (bits != NULL &&
                    (bits[i >> 6] & ((uint64_t)1 << (i & 63))) == 0) {
                continue;
            }
            int32_t g = sc.code[a + i];
            cnt[g]++;
            if (sumi != NULL) {
                if (__builtin_add_overflow(sumi[g], vcol.i[a + i],
                                           &sumi[g])) {
                    return luaL_error(L, "col: integer overflow");
                }
            } else if (sumf != NULL) {
                sumf[g] += vcol.f[a + i];
            }
        }
    }
    /* {keys, counts, sums?} - parallel, first-appearance order. */
    lua_createtable(L, 0, wantSum ? 3 : 2);
    lua_createtable(L, (int)k, 0);
    for (int64_t g = 0; g < k; g++) {
        if (bmode == 'd') {
            lua_pushlstring(L, sc.arena + sc.dictOff[g],
                            (size_t)sc.dictLen[g]);
        } else {
            lua_pushinteger(L, (lua_Integer)ikeys[g]);
        }
        lua_rawseti(L, -2, (lua_Integer)(g + 1));
    }
    lua_setfield(L, -2, "keys");
    lua_createtable(L, (int)k, 0);
    for (int64_t g = 0; g < k; g++) {
        lua_pushinteger(L, (lua_Integer)cnt[g]);
        lua_rawseti(L, -2, (lua_Integer)(g + 1));
    }
    lua_setfield(L, -2, "counts");
    if (wantSum) {
        lua_createtable(L, (int)k, 0);
        for (int64_t g = 0; g < k; g++) {
            if (sumi != NULL) {
                lua_pushinteger(L, (lua_Integer)sumi[g]);
            } else {
                lua_pushnumber(L, (lua_Number)sumf[g]);
            }
            lua_rawseti(L, -2, (lua_Integer)(g + 1));
        }
        lua_setfield(L, -2, "sums");
    }
    return 1;
}

/* col.distinct(h, FIELD) - the dictionary's size; col.values(h, FIELD) -
 * the distinct strings as a 1-based sequence, in first-appearance order
 * (a GUI's filter dropdown). The dictionary is POOL-wide: a view over a
 * subrange still answers for the whole pool's column. Both refuse by
 * name on a span-mode column - past the cardinality escape there is no
 * dictionary to answer from. */
static int
LDistinct(lua_State *L)
{
    int wantValues = (int)lua_tointeger(L, lua_upvalueindex(1));
    const char *field = luaL_checkstring(L, 2);
    int poolNum;
    int64_t a, b;
    ResolveView(L, 1, &poolNum, &a, &b);
    EngineStrCol sc;
    char mode = ResolveStrColumn(L, poolNum, field, &sc);
    if (mode == 'n') {
        return luaL_error(L, "col: field %s is not a string", field);
    }
    if (mode == 'p' && sc.rows == 0) {
        /* A zero-row column has no dictionary by construction; the
         * limit refusal would be a lying name. Answer empty. */
        if (!wantValues) {
            lua_pushinteger(L, 0);
        } else {
            lua_createtable(L, 0, 0);
        }
        return 1;
    }
    if (mode == 'p') {
        return luaL_error(L,
            "col: field %s is past the dictionary limit (span mode)",
            field);
    }
    if (!wantValues) {
        lua_pushinteger(L, (lua_Integer)sc.dictN);
        return 1;
    }
    lua_createtable(L, (int)sc.dictN, 0);
    for (int64_t d = 0; d < sc.dictN; d++) {
        lua_pushlstring(L, sc.arena + sc.dictOff[d], (size_t)sc.dictLen[d]);
        lua_rawseti(L, -2, (lua_Integer)(d + 1));
    }
    return 1;
}

static int
LCount(lua_State *L)
{
    if (luaL_testudata(L, 1, COL_SEL_META) != NULL) {
        ColSel *s = (ColSel *)lua_touserdata(L, 1);
        lua_pushinteger(L, (lua_Integer)CountBits(s->bits, s->b - s->a));
        return 1;
    }
    int poolNum;
    int64_t a, b;
    ResolveView(L, 1, &poolNum, &a, &b);
    lua_pushinteger(L, (lua_Integer)(b - a));
    return 1;
}

/* Streaming-bandwidth microbench for the bench lane's step 0(c): mb
 * megabytes summed three times, best pass wins; returns MB/s. Internal
 * and undeclared, like _scalar and _avx2. */
static int
LBandwidth(lua_State *L)
{
    int64_t mb = luaL_optinteger(L, 1, 64);
    if (mb < 1 || mb > 1024) {
        return luaL_error(L, "col: argument type (1..1024 MB)");
    }
    size_t n = (size_t)mb * 1024 * 1024 / 8;
    int64_t *v = (int64_t *)malloc(n * 8);
    if (v == NULL) {
        return luaL_error(L, "col: bench buffer does not fit");
    }
    for (size_t i = 0; i < n; i++) {
        v[i] = (int64_t)(i & 1023);
    }
    LARGE_INTEGER f, t0, t1;
    QueryPerformanceFrequency(&f);
    double best = 1e300;
    int64_t sink = 0;
    for (int pass = 0; pass < 3; pass++) {
        QueryPerformanceCounter(&t0);
        int64_t total = 0;
        if (!SumI64(v, (int64_t)n, &total)) {
            free(v);
            return luaL_error(L, "col: integer overflow");
        }
        QueryPerformanceCounter(&t1);
        sink ^= total;
        double sec = (double)(t1.QuadPart - t0.QuadPart) / (double)f.QuadPart;
        if (sec < best) {
            best = sec;
        }
    }
    free(v);
    lua_pushnumber(L, ((double)mb / best));
    lua_pushinteger(L, (lua_Integer)sink);
    return 2;
}

/* col.topn(h, FIELD, N, SEL_or_nil, DIR) - the order-by verb: the N
 * rows with the largest ("desc") or smallest ("asc") FIELD under SEL,
 * AS ROWS in pool column order, like col.rows. One pass, a bounded
 * heap of (value, row): the kept set is the strongest N, ties broken
 * by row order (earlier rows win a place; output ties ascend by row).
 * NaN never enters the heap (the min/max law). N above 4096 refuses
 * by name; strings refuse through the numeric resolution. */
typedef struct {
    int64_t vi;
    double vf;
    int64_t row;                     /* view-relative */
} TopEnt;

/* Is x weaker than y in the kept set? For desc the weakest is the
 * SMALLEST value (evicted first); ties: the LARGER row index is
 * weaker, so earlier rows survive. asc mirrors the value sense. */
static int
TopWeaker(const TopEnt *x, const TopEnt *y, int isF, int desc)
{
    if (isF) {
        if (x->vf != y->vf) {
            return desc ? (x->vf < y->vf) : (x->vf > y->vf);
        }
    } else {
        if (x->vi != y->vi) {
            return desc ? (x->vi < y->vi) : (x->vi > y->vi);
        }
    }
    return x->row > y->row;
}

static void
TopSiftDown(TopEnt *heap, int64_t nheap, int64_t at, int isF, int desc)
{
    /* The root is the WEAKEST kept entry (a min-heap in strength). */
    for (;;) {
        int64_t l = 2 * at + 1;
        int64_t r = l + 1;
        int64_t weakest = at;
        if (l < nheap && TopWeaker(&heap[l], &heap[weakest], isF, desc)) {
            weakest = l;
        }
        if (r < nheap && TopWeaker(&heap[r], &heap[weakest], isF, desc)) {
            weakest = r;
        }
        if (weakest == at) {
            return;
        }
        TopEnt t = heap[at];
        heap[at] = heap[weakest];
        heap[weakest] = t;
        at = weakest;
    }
}

static int
LTopN(lua_State *L)
{
    ColArg col;
    const char *field = luaL_checkstring(L, 2);
    ResolveColumn(L, 1, field, &col);
    int64_t nwant = (int64_t)luaL_checkinteger(L, 3);
    if (nwant < 0) {
        return luaL_error(L, "col: argument type (N >= 0)");
    }
    if (nwant > 4096) {
        return luaL_error(L, "col: topn asks more than 4096");
    }
    const uint64_t *bits = NULL;
    if (!lua_isnoneornil(L, 4)) {
        ColSel *s = (ColSel *)luaL_checkudata(L, 4, COL_SEL_META);
        if (s->poolNum != col.poolNum || s->a != col.a || s->b != col.b) {
            return luaL_error(L, "col: selection is bound to another view");
        }
        bits = s->bits;
    }
    static const char *const kDirs[] = { "desc", "asc", NULL };
    int desc = luaL_checkoption(L, 5, NULL, kDirs) == 0;
    int isF = (col.type == 'f');
    int64_t n = col.b - col.a;
    TopEnt *heap = (TopEnt *)lua_newuserdatauv(L,
        (size_t)(nwant > 0 ? nwant : 1) * sizeof(TopEnt), 0);
    int64_t nheap = 0;
    for (int64_t i = 0; i < n; i++) {
        if (bits != NULL &&
                (bits[i >> 6] & ((uint64_t)1 << (i & 63))) == 0) {
            continue;
        }
        TopEnt e;
        e.row = i;
        if (isF) {
            e.vf = col.f[col.a + i];
            if (e.vf != e.vf) {
                continue;                          /* NaN never enters */
            }
            e.vi = 0;
        } else {
            e.vi = col.i[col.a + i];
            e.vf = 0;
        }
        if (nheap < nwant) {
            /* Grow: sift the new entry up toward the weak root. */
            int64_t at = nheap++;
            heap[at] = e;
            while (at > 0) {
                int64_t up = (at - 1) / 2;
                if (!TopWeaker(&heap[at], &heap[up], isF, desc)) {
                    break;
                }
                TopEnt t = heap[at];
                heap[at] = heap[up];
                heap[up] = t;
                at = up;
            }
        } else if (nwant > 0 && TopWeaker(&heap[0], &e, isF, desc)) {
            heap[0] = e;
            TopSiftDown(heap, nheap, 0, isF, desc);
        }
    }
    /* Strong-to-weak output: repeatedly pop the weak root to the back. */
    for (int64_t m = nheap; m > 1; m--) {
        TopEnt t = heap[0];
        heap[0] = heap[m - 1];
        heap[m - 1] = t;
        TopSiftDown(heap, m - 1, 0, isF, desc);
    }
    RowsCol cols[64];
    int ncols = ResolveRowsCols(col.poolNum, cols);
    lua_createtable(L, (int)nheap, 0);
    for (int64_t r = 0; r < nheap; r++) {
        PushRowSeq(L, cols, ncols, col.a + heap[r].row);
        lua_rawseti(L, -2, (lua_Integer)(r + 1));
    }
    return 1;
}

static void
BindImpl(lua_State *L, const ColImpl *impl)
{
    /* table on top: the impl-paired primitives (P3's A/B subjects) */
    lua_pushlightuserdata(L, (void *)(uintptr_t)impl);
    lua_pushcclosure(L, LFilter, 1);
    lua_setfield(L, -2, "filter");
    lua_pushlightuserdata(L, (void *)(uintptr_t)impl);
    lua_pushcclosure(L, LSum, 1);
    lua_setfield(L, -2, "sum");
}

static void
BindCommon(lua_State *L)
{
    /* table on top: the scalar-only vocabulary (P3 earned no twins) */
    lua_pushcfunction(L, LSumWhere);
    lua_setfield(L, -2, "sumwhere");
    lua_pushcfunction(L, LCount);
    lua_setfield(L, -2, "count");
    lua_pushinteger(L, 0);
    lua_pushcclosure(L, LMinMax, 1);
    lua_setfield(L, -2, "min");
    lua_pushinteger(L, 1);
    lua_pushcclosure(L, LMinMax, 1);
    lua_setfield(L, -2, "max");
    lua_pushinteger(L, 0);
    lua_pushcclosure(L, LBand, 1);
    lua_setfield(L, -2, "band");
    lua_pushinteger(L, 1);
    lua_pushcclosure(L, LBand, 1);
    lua_setfield(L, -2, "bor");
    lua_pushcfunction(L, LBnot);
    lua_setfield(L, -2, "bnot");
    lua_pushinteger(L, 0);
    lua_pushcclosure(L, LDistinct, 1);
    lua_setfield(L, -2, "distinct");
    lua_pushinteger(L, 1);
    lua_pushcclosure(L, LDistinct, 1);
    lua_setfield(L, -2, "values");
    lua_pushcfunction(L, LRows);
    lua_setfield(L, -2, "rows");
    lua_pushinteger(L, 0);
    lua_pushcclosure(L, LGroup, 1);
    lua_setfield(L, -2, "groupcount");
    lua_pushinteger(L, 1);
    lua_pushcclosure(L, LGroup, 1);
    lua_setfield(L, -2, "groupsum");
    lua_pushcfunction(L, LTopN);
    lua_setfield(L, -2, "topn");
}

void
MachteldCol_Open(lua_State *S)
{
    luaL_newmetatable(S, COL_SEL_META);
    lua_pop(S, 1);
    lua_createtable(S, 0, 12);
    BindImpl(S, &kScalar);                 /* the public dialect: scalar C */
    BindCommon(S);
    lua_createtable(S, 0, 10);
    BindImpl(S, &kScalar);
    BindCommon(S);
    lua_setfield(S, -2, "_scalar");        /* the normative twins, by name */
    lua_createtable(S, 0, 2);
    BindImpl(S, &kAvx2);
    lua_setfield(S, -2, "_avx2");          /* bench lane only, P3 */
    lua_pushcfunction(S, LBandwidth);
    lua_setfield(S, -2, "_bw");
    lua_setglobal(S, "col");
}
