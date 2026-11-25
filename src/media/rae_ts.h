/* MPEG transport stream audio extraction. Adapted from Rae (MIT), see licenses/rae.txt. */
#ifndef RAE_TS_H
#define RAE_TS_H

#include "rae_common.h"

#define RAE_TS_PACKET 188

/* Receives the next fragment of the audio elementary stream (PES payload
 * bytes, in stream order, PES headers stripped).  len ≥ 1.                  */
typedef void (*rae_ts_pes_cb)(void *user, const uint8_t *data, size_t len);

typedef struct rae_ts rae_ts;           /* opaque; owned by rae_ts.c */

typedef struct rae_ts_stats {
    uint64_t packets;            /* 188-byte packets accepted                */
    uint64_t error_packets;      /* transport_error_indicator drops          */
    uint64_t resyncs;            /* sync-loss events                         */
    uint64_t dropped_bytes;      /* bytes skipped hunting for sync           */
    uint64_t pat_seen, pmt_seen; /* sections parsed (≥1 each once locked)    */
    int      pmt_pid;            /* -1 until PAT parsed                      */
    int      audio_pid;          /* -1 until PMT parsed                      */
    uint8_t  audio_stream_type;  /* 0x0F ADTS AAC / 0x03,0x04 MP3 / 0 unset  */
    uint64_t audio_packets;      /* TS packets on the audio PID              */
    uint64_t pes_starts;         /* PUSI count on the audio PID              */
    uint64_t payload_bytes;      /* total bytes handed to the callback       */
    uint64_t cc_discontinuities; /* continuity-counter breaks (counted, and
                                    payload dropped to next PUSI)            */
    uint64_t dup_packets;        /* duplicate-CC packets dropped             */
} rae_ts_stats;

/* cb required; user passed through.  RAE_E_OOM / RAE_E_INVALID. */
rae_err rae_ts_create(rae_ts **out, rae_ts_pes_cb cb, void *user);

/* Feed any number of bytes.  Returns RAE_OK normally (garbage input is
 * resync'd, never an error), RAE_E_UNSUPPORTED once a PMT proves there is no
 * supported audio ES, RAE_E_OOM, RAE_E_INVALID.  After RAE_E_UNSUPPORTED the
 * demux is dead: only destroy/reset are legal.                              */
rae_err rae_ts_feed(rae_ts *t, const uint8_t *chunk, size_t len);

/* Segment boundary (HLS calls this after each segment EOF): discard any
 * buffered partial TS packet / partial PES header.  PAT/PMT lock and CC
 * state are RETAINED — consecutive segments of one variant are a continuous
 * transport stream (CC runs across segment boundaries on USP origins).      */
void rae_ts_flush(rae_ts *t);

/* Full reset to the just-created state (PAT/PMT forgotten, CC forgotten,
 * stats KEPT — they are per-demux-lifetime).  HLS calls this on
 * #EXT-X-DISCONTINUITY and on live-edge jumps.                              */
void rae_ts_reset(rae_ts *t);

/* Live view of the counters (same thread as feed; snapshot, no locking). */
const rae_ts_stats *rae_ts_get_stats(const rae_ts *t);

void rae_ts_destroy(rae_ts *t);

#endif /* RAE_TS_H */
