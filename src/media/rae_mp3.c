/* Incremental minimp3 decoder. Adapted from Rae (MIT), see licenses/rae.txt. */

#include "rae_common.h"
#include "rae_mp3.h"

#include <stdlib.h>
#include <string.h>

#define MINIMP3_IMPLEMENTATION
#define MINIMP3_FLOAT_OUTPUT
#include "../vendor/minimp3.h"

struct rae_mp3 {
    mp3dec_t dec;
    uint8_t *buf;                   /* accumulator; [start,end) unconsumed */
    size_t   cap;
    size_t   start;
    size_t   end;
    float    pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];  /* borrowed output buffer */
};

size_t rae_mp3_pending(const rae_mp3 *m) { return m->end - m->start; }

rae_err rae_mp3_create(rae_mp3 **out)
{
    if (out == nullptr) {
        rae_logf("mp3: create: NULL out pointer");
        return RAE_E_INVALID;
    }
    *out = nullptr;

    rae_mp3 *m = calloc(1, sizeof *m);
    if (m == nullptr) {
        rae_logf("mp3: create: out of memory (%zu bytes)", sizeof *m);
        return RAE_E_OOM;
    }
    mp3dec_init(&m->dec);
    *out = m;
    return RAE_OK;
}

void rae_mp3_destroy(rae_mp3 *m)
{
    if (m == nullptr)
        return;
    free(m->buf);
    free(m);
}

void rae_mp3_reset(rae_mp3 *m)
{
    if (m == nullptr)
        return;
    m->start = m->end = 0;          /* keep the allocation for reuse */
    /* mp3dec_init only clears the cached header, but that forces the next
     * decode through minimp3's resync path, which memsets the whole decoder
     * (overlap + reservoir) — a genuinely fresh decoder, as reconnect needs. */
    mp3dec_init(&m->dec);
}

rae_err rae_mp3_feed(rae_mp3 *m, const uint8_t *bytes, size_t len)
{
    if (m == nullptr || (bytes == nullptr && len > 0)) {
        rae_logf("mp3: feed: NULL argument");
        return RAE_E_INVALID;
    }
    if (len == 0)
        return RAE_OK;

    if (m->start == m->end)
        m->start = m->end = 0;      /* empty: compaction for free */

    size_t used = m->end - m->start;
    if (used + len > RAE_MP3_BUF_MAX) {
        rae_logf("mp3: accumulator full (%zu buffered + %zu fed > %u cap) with "
                 "no decodable frame — undecodable stream",
                 used, len, RAE_MP3_BUF_MAX);
        return RAE_E_FORMAT;
    }

    if (m->end + len > m->cap && m->start > 0) {   /* compact before growing */
        memmove(m->buf, m->buf + m->start, used);
        m->start = 0;
        m->end = used;
    }
    if (used + len > m->cap) {
        size_t newcap = (m->cap != 0) ? m->cap : 16384;
        while (newcap < used + len)
            newcap *= 2;
        if (newcap > RAE_MP3_BUF_MAX)
            newcap = RAE_MP3_BUF_MAX;              /* still ≥ used+len (cap check above) */
        uint8_t *nb = realloc(m->buf, newcap);
        if (nb == nullptr) {
            rae_logf("mp3: feed: out of memory growing accumulator to %zu bytes",
                     newcap);
            return RAE_E_OOM;       /* old buffer intact; instance still usable */
        }
        m->buf = nb;
        m->cap = newcap;
    }

    memcpy(m->buf + m->end, bytes, len);
    m->end += len;
    return RAE_OK;
}

rae_err rae_mp3_pull(rae_mp3 *m, const float **samples, size_t *out_floats,
                     int *sample_rate, int *channels)
{
    if (m == nullptr || samples == nullptr || out_floats == nullptr ||
        sample_rate == nullptr || channels == nullptr) {
        rae_logf("mp3: pull: NULL argument");
        return RAE_E_INVALID;
    }
    *samples = nullptr;
    *out_floats = 0;
    *sample_rate = 0;
    *channels = 0;

    for (;;) {
        size_t avail = m->end - m->start;
        if (avail == 0) {
            m->start = m->end = 0;
            return RAE_OK;                          /* need more input */
        }

        /* avail ≤ RAE_MP3_BUF_MAX (256 KiB), so the int cast is safe. */
        /* An incomplete/unconfirmed tail makes minimp3's resync path clear
         * decoder state before it reports that no frame can be consumed.  A
         * network chunk ending one to three bytes into the next MP3 header is
         * enough to trigger that path.  Probe on a copy with pcm == NULL:
         * this uses minimp3's public framing mode without touching the real
         * bit reservoir or synthesis overlap.  Only a confirmed complete
         * frame is allowed to reach the stateful decode below. */
        mp3dec_t probe = m->dec;
        mp3dec_frame_info_t probe_info = {};
        int framed = mp3dec_decode_frame(&probe, m->buf + m->start, (int)avail,
                                         nullptr, &probe_info);
        if (framed <= 0)
            return RAE_OK;

        mp3dec_frame_info_t fi = {};
        int n = mp3dec_decode_frame(&m->dec, m->buf + m->start, (int)avail,
                                    m->pcm, &fi);
        if (n > 0) {
            m->start += (size_t)fi.frame_bytes;     /* garbage prefix + frame */
            *samples = m->pcm;
            *out_floats = (size_t)n * (size_t)fi.channels;
            *sample_rate = fi.hz;
            *channels = fi.channels;
            return RAE_OK;
        }
        if (fi.frame_bytes <= 0)
            return RAE_OK;          /* incomplete frame at the front (or sync
                                       unconfirmed against the next header) —
                                       genuinely need more bytes              */
        if ((size_t)fi.frame_bytes > avail) {       /* minimp3 never does this */
            rae_logf("mp3: decoder claimed %d consumed of %zu available — "
                     "dropping buffer and resyncing", fi.frame_bytes, avail);
            m->start = m->end = 0;
            mp3dec_init(&m->dec);
            return RAE_OK;
        }
        /* Junk / ID3 / corrupt or reservoir-priming frame skipped: consume
         * frame_bytes and retry.  Progress ≥ 1 byte per pass ⇒ this loop is
         * bounded by avail.                                                  */
        m->start += (size_t)fi.frame_bytes;
    }
}
