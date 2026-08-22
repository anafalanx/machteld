/* col.c -- the primitive palette: vectorized column operations for kernels
 * (machteld 0.13.0, docs/engine.md "The col library").
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

enum { OP_LT, OP_LE, OP_GT, OP_GE, OP_EQ, OP_NE };

static const char *const kOpNames[] = {
    "lt", "le", "gt", "ge", "eq", "ne", NULL
};

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
