/* Single-producer PCM ring buffer. Adapted from Rae (MIT), see licenses/rae.txt. */
#ifndef RAE_RING_H
#define RAE_RING_H

#include "rae_common.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct rae_ring {
    float  *buf;            /* owned by the ring (init mallocs, free frees)   */
    size_t  cap;            /* capacity in floats; always a power of two      */
    size_t  mask;           /* cap - 1                                        */
    /* head/tail on separate cache lines: no false sharing producer↔consumer */
    alignas(64) _Atomic uint64_t head;   /* total floats ever pushed (producer-owned) */
    alignas(64) _Atomic uint64_t tail;   /* total floats ever pulled (consumer-owned) */
} rae_ring;

/* Allocate. capacity_floats is rounded UP to the next power of two; the full
 * rounded capacity is usable.  Returns RAE_E_OOM / RAE_E_INVALID(0 cap).
 * Typical sizing (tuner): RAE_RING_SECONDS * sample_rate * channels.        */
static inline rae_err rae_ring_init(rae_ring *r, size_t capacity_floats) {
    if (!r || capacity_floats == 0) return RAE_E_INVALID;
    size_t cap = 1;
    while (cap < capacity_floats) cap <<= 1;
    float *buf = (float *)calloc(cap, sizeof(float));
    if (!buf) return RAE_E_OOM;
    r->buf = buf; r->cap = cap; r->mask = cap - 1;
    atomic_store_explicit(&r->head, 0, memory_order_relaxed);
    atomic_store_explicit(&r->tail, 0, memory_order_relaxed);
    return RAE_OK;
}

/* PRODUCER ONLY.  Copies up to n floats; returns the count actually pushed
 * (< n when full — the producer then waits per the backpressure contract;
 * the ring itself never blocks). */
static inline size_t rae_ring_push(rae_ring *r, const float *src, size_t n) {
    uint64_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    size_t   space = (size_t)(r->cap - (size_t)(head - tail));
    if (n > space) n = space;
    if (n == 0) return 0;
    size_t i     = (size_t)head & r->mask;
    size_t first = r->cap - i; if (first > n) first = n;
    memcpy(r->buf + i, src, first * sizeof(float));
    memcpy(r->buf, src + first, (n - first) * sizeof(float));
    atomic_store_explicit(&r->head, head + n, memory_order_release);
    return n;
}

/* CONSUMER ONLY.  Copies up to n floats into dst; returns the count pulled
 * (< n when the ring runs dry — the render thread zero-fills the remainder
 * and counts ONE underrun event, see rae_wasapi.h). */
static inline size_t rae_ring_pull(rae_ring *r, float *dst, size_t n) {
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    size_t   avail = (size_t)(head - tail);
    if (n > avail) n = avail;
    if (n == 0) return 0;
    size_t i     = (size_t)tail & r->mask;
    size_t first = r->cap - i; if (first > n) first = n;
    memcpy(dst, r->buf + i, first * sizeof(float));
    memcpy(dst + first, r->buf, (n - first) * sizeof(float));
    atomic_store_explicit(&r->tail, tail + n, memory_order_release);
    return n;
}

/* ANY THREAD.  Floats currently buffered (approximate under concurrency;
 * exact when either side is idle).  seconds = level / (sr * ch). */
static inline size_t rae_ring_level(const rae_ring *r) {
    uint64_t head = atomic_load_explicit((_Atomic uint64_t *)&r->head, memory_order_acquire);
    uint64_t tail = atomic_load_explicit((_Atomic uint64_t *)&r->tail, memory_order_acquire);
    return (size_t)(head - tail);
}

/* QUIESCENT ONLY (no concurrent push/pull — render thread closed/not yet
 * open).  Empties the ring; capacity unchanged.  Used between formats. */
static inline void rae_ring_reset(rae_ring *r) {
    atomic_store_explicit(&r->head, 0, memory_order_relaxed);
    atomic_store_explicit(&r->tail, 0, memory_order_relaxed);
}

/* QUIESCENT ONLY.  Frees the buffer; struct may be re-init'ed afterwards. */
static inline void rae_ring_free(rae_ring *r) {
    if (r && r->buf) { free(r->buf); r->buf = NULL; r->cap = r->mask = 0; }
}

#endif /* RAE_RING_H */
