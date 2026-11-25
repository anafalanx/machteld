/* ADTS frame reader. Adapted from Rae (MIT), see licenses/rae.txt. */

#include "rae_common.h"
#include "rae_adts.h"

#include <stdlib.h>
#include <string.h>

#define ADTS_BUF_MIN 16384          /* initial capacity; doubles as needed   */

/* sampling_frequency_index 0–12 (13/14/15 are invalid in a header). */
static const int adts_hz[13] = {
    96000, 88200, 64000, 48000, 44100, 32000, 24000,
    22050, 16000, 12000, 11025, 8000, 7350,
};

struct rae_adts {
    uint8_t *buf;
    size_t   cap;
    size_t   len;               /* valid bytes in buf                        */
    size_t   pos;               /* consumed up to here (compacted on feed)   */
    bool     locked, finished;
    uint64_t frames;
    uint64_t resyncs;
};

size_t rae_adts_pending(const rae_adts *a) { return a->len - a->pos; }
void rae_adts_finish(rae_adts *a) { a->finished = true; }

typedef struct adts_hdr {
    size_t frame_len;           /* whole frame incl. header (+CRC)           */
    int    sample_rate;
    int    channels;            /* channel_configuration, 0–7                */
    int    profile;             /* Audio Object Type = ADTS profile + 1      */
} adts_hdr;

/* True iff p (≥ 7 readable bytes) holds a valid ADTS header. */
static bool adts_parse(const uint8_t *p, adts_hdr *h)
{
    if (p[0] != 0xFF || (p[1] & 0xF6) != 0xF0)  /* 0xFFF sync + layer == 00  */
        return false;
    const int sfi = (p[2] >> 2) & 0x0F;
    if (sfi > 12)                               /* 13/14/15 ⇒ invalid        */
        return false;
    const bool   prot_absent = (p[1] & 0x01) != 0;
    const size_t hdr_len     = prot_absent ? 7 : 9;  /* CRC included, not    */
    const size_t fl = ((size_t)(p[3] & 0x03) << 11)  /* validated            */
                    | ((size_t)p[4] << 3)
                    | ((size_t)p[5] >> 5);
    if (fl < hdr_len)                           /* length can't fit header   */
        return false;
    h->frame_len   = fl;
    h->sample_rate = adts_hz[sfi];
    h->channels    = ((p[2] & 0x01) << 2) | (p[3] >> 6);
    h->profile     = ((p[2] >> 6) & 0x03) + 1;
    return true;
}

/* ── public API ───────────────────────────────────────────────────────── */

rae_err rae_adts_create(rae_adts **out)
{
    if (!out) {
        rae_logf("adts: create: out is null");
        return RAE_E_INVALID;
    }
    *out = nullptr;
    rae_adts *a = calloc(1, sizeof *a);
    if (!a) {
        rae_logf("adts: create: out of memory (%zu bytes)", sizeof *a);
        return RAE_E_OOM;
    }
    a->buf = malloc(ADTS_BUF_MIN);
    if (!a->buf) {
        rae_logf("adts: create: out of memory (%d-byte buffer)", ADTS_BUF_MIN);
        free(a);
        return RAE_E_OOM;
    }
    a->cap = ADTS_BUF_MIN;
    *out = a;
    return RAE_OK;
}

void rae_adts_destroy(rae_adts *a)
{
    if (!a)
        return;
    free(a->buf);
    free(a);
}

void rae_adts_reset(rae_adts *a)
{
    if (!a)
        return;
    a->len    = 0;
    a->pos    = 0;
    a->locked = false;          /* counters kept: per-instance lifetime      */
}

rae_err rae_adts_feed(rae_adts *a, const uint8_t *bytes, size_t len)
{
    if (!a || (!bytes && len > 0)) {
        rae_logf("adts: feed: invalid arguments");
        return RAE_E_INVALID;
    }
    if (len == 0)
        return RAE_OK;
    if (a->pos > 0) {           /* compact: leftover is at most a partial    */
        a->len -= a->pos;       /* frame plus an unverified tail — cheap     */
        if (a->len > 0)
            memmove(a->buf, a->buf + a->pos, a->len);
        a->pos = 0;
    }
    if (len > a->cap - a->len) {
        size_t ncap = a->cap;
        while (ncap - a->len < len)
            ncap *= 2;
        uint8_t *nb = realloc(a->buf, ncap);
        if (!nb) {
            rae_logf("adts: feed: out of memory growing buffer to %zu bytes",
                     ncap);
            return RAE_E_OOM;   /* old buffer intact; framer still usable    */
        }
        a->buf = nb;
        a->cap = ncap;
    }
    memcpy(a->buf + a->len, bytes, len);
    a->len += len;
    return RAE_OK;
}

bool rae_adts_next(rae_adts *a, rae_adts_frame *out)
{
    if (!a || !out)
        return false;
    for (;;) {
        if (a->len - a->pos < 7)            /* not even a header yet         */
            return false;

        if (!a->locked) {                   /* acquisition: double-sync rule */
            size_t i = a->pos;
            while (a->len - i >= 7) {
                const uint8_t *c = a->buf + i;
                adts_hdr ch;
                if (adts_parse(c, &ch)) {
                    if (a->finished && ch.frame_len == a->len - i) {
                        a->locked = true;
                        break;
                    }
                    if (i + ch.frame_len + 2 > a->len) {
                        a->pos = i;         /* can't verify the second sync  */
                        return false;       /* yet — keep candidate, wait    */
                    }
                    if (c[ch.frame_len] == 0xFF &&
                        (c[ch.frame_len + 1] & 0xF6) == 0xF0) {
                        a->locked = true;
                        break;
                    }
                }
                i++;                        /* garbage byte: skip and rescan */
            }
            a->pos = i;
            if (!a->locked)
                return false;               /* scanned out; tail (<7) kept   */
        }

        const uint8_t *p = a->buf + a->pos;
        adts_hdr h;
        if (!adts_parse(p, &h)) {           /* lock lost mid-stream          */
            a->locked = false;
            a->resyncs++;
            a->pos++;
            continue;
        }
        if (a->len - a->pos < h.frame_len)  /* partial frame: feed more      */
            return false;

        out->data        = p;               /* borrowed: dies at next call   */
        out->len         = h.frame_len;
        out->sample_rate = h.sample_rate;
        out->channels    = h.channels;      /* 0 = in-band PCE: reported     */
        out->profile     = h.profile;       /* honestly, consumer rejects    */
        a->pos += h.frame_len;
        a->frames++;
        return true;
    }
}

uint64_t rae_adts_frames_emitted(const rae_adts *a)
{
    return a ? a->frames : 0;
}

uint64_t rae_adts_resyncs(const rae_adts *a)
{
    return a ? a->resyncs : 0;
}

int rae_adts_freq_index(int sample_rate)
{
    for (int i = 0; i < 13; i++)
        if (adts_hz[i] == sample_rate)
            return i;
    return -1;
}
