/* MPEG transport stream audio extraction. Adapted from Rae (MIT), see licenses/rae.txt. */

#include "rae_common.h"
#include "rae_ts.h"

#include <stdlib.h>
#include <string.h>

#define TS_SYNC        0x47
#define TS_NULL_PID    0x1FFF
#define TS_PES_HDR_MAX (9 + 255)   /* 6+3 fixed bytes + PES_header_data_length */

typedef enum {
    PES_IDLE,   /* nothing open: skip payload until the next PUSI            */
    PES_HDR,    /* accumulating the 9+N byte PES header (may span packets)   */
    PES_BODY,   /* emitting payload bytes until the next PUSI                */
} ts_pes_state;

struct rae_ts {
    rae_ts_pes_cb cb;
    void         *user;
    rae_ts_stats  stats;        /* pmt_pid / audio_pid double as the lock    */

    /* 188-byte packet assembly across feed chunks */
    uint8_t pbuf[RAE_TS_PACKET];
    size_t  pbuf_len;
    bool    pbuf_prov;          /* pbuf[0] is a PROVISIONAL sync candidate
                                   (tail of a hunt): must be re-judged against
                                   the byte after its window before parsing   */
    bool    hunting;            /* mid sync-hunt: this loss already counted  */

    /* audio PES reassembly */
    ts_pes_state pes_state;
    uint8_t phdr[TS_PES_HDR_MAX];
    size_t  phdr_have, phdr_need;
    int     prev_cc;            /* -1 = no audio payload packet seen yet     */

    bool dead;                  /* RAE_E_UNSUPPORTED delivered: feed refused */
    bool in_cb;                 /* re-entrancy guard around the callback     */

    /* warn-once latches (instance lifetime — avoid per-packet log spam) */
    bool warned_long_section, warned_lock_change, warned_bad_af,
         warned_bad_pes, warned_scrambled;
};

/* ── helpers ──────────────────────────────────────────────────────────── */

static void ts_sync_loss(rae_ts *t, size_t skipped)
{
    if (!t->hunting) {          /* one resync event per loss, however many  */
        t->hunting = true;      /* feeds the hunt spans                      */
        t->stats.resyncs++;
    }
    t->stats.dropped_bytes += skipped;
}

static void ts_emit(rae_ts *t, const uint8_t *p, size_t n)
{
    if (n == 0)
        return;
    t->stats.payload_bytes += n;
    t->in_cb = true;
    t->cb(t->user, p, n);       /* borrowed pointer: callback-duration only */
    t->in_cb = false;
}

/* Locate a PSI section inside one packet payload: pointer_field on PUSI,
 * table_id + section_length checks.  Returns nullptr if not parseable here
 * (sections are assumed to fit one TS packet — true for radio PAT/PMT). */
static const uint8_t *ts_psi_section(rae_ts *t, bool pusi, const uint8_t *pl,
                                     size_t n, uint8_t table_id, size_t *total)
{
    if (!pusi || n < 1)
        return nullptr;                     /* continuation: unsupported     */
    const size_t p = 1 + (size_t)pl[0];     /* pointer_field                 */
    if (p + 3 > n)
        return nullptr;
    const uint8_t *sec = pl + p;
    if (sec[0] != table_id)
        return nullptr;
    const size_t len = 3 + (size_t)(((sec[1] & 0x0F) << 8) | sec[2]);
    if (len > n - p) {
        if (!t->warned_long_section) {
            t->warned_long_section = true;
            rae_logf("ts: PSI section (table 0x%02X) length %zu exceeds one "
                     "packet — ignored", (unsigned)table_id, len);
        }
        return nullptr;
    }
    *total = len;
    return sec;
}

static void ts_pat(rae_ts *t, bool pusi, const uint8_t *pl, size_t n)
{
    size_t total = 0;
    const uint8_t *sec = ts_psi_section(t, pusi, pl, n, 0x00, &total);
    if (!sec || total < 12)                 /* 8 fixed + 4 CRC minimum       */
        return;
    t->stats.pat_seen++;

    int pmt = -1;
    for (size_t i = 8; i + 4 <= total - 4; i += 4) {
        const int prog = (sec[i] << 8) | sec[i + 1];
        const int pid  = ((sec[i + 2] & 0x1F) << 8) | sec[i + 3];
        if (prog != 0) {                    /* first real program wins       */
            pmt = pid;
            break;
        }
    }
    if (pmt < 0)
        return;
    if (t->stats.pmt_pid >= 0) {            /* locked: re-parses must agree  */
        if (pmt != t->stats.pmt_pid && !t->warned_lock_change) {
            t->warned_lock_change = true;
            rae_logf("ts: PAT changed PMT pid %d -> %d after lock — ignored",
                     t->stats.pmt_pid, pmt);
        }
        return;
    }
    t->stats.pmt_pid = pmt;
}

static rae_err ts_pmt(rae_ts *t, bool pusi, const uint8_t *pl, size_t n)
{
    size_t total = 0;
    const uint8_t *sec = ts_psi_section(t, pusi, pl, n, 0x02, &total);
    if (!sec || total < 16)                 /* 12 fixed + 4 CRC minimum      */
        return RAE_OK;
    const size_t pil = ((sec[10] & 0x0F) << 8) | sec[11];  /* program_info  */
    size_t i = 12 + pil;
    const size_t end = total - 4;           /* CRC excluded                  */
    if (i > end)
        return RAE_OK;
    t->stats.pmt_seen++;

    int     apid  = -1;
    uint8_t stype = 0;
    bool    latm  = false;
    while (i + 5 <= end) {
        const uint8_t st   = sec[i];
        const int     epid = ((sec[i + 1] & 0x1F) << 8) | sec[i + 2];
        const size_t  esil = ((sec[i + 3] & 0x0F) << 8) | sec[i + 4];
        if (st == 0x0F || st == 0x03 || st == 0x04) {   /* ADTS AAC / MPEG  */
            apid  = epid;
            stype = st;
            break;
        }
        if (st == 0x11)
            latm = true;
        i += 5 + esil;
    }

    if (t->stats.audio_pid >= 0) {          /* locked: re-parses must agree  */
        if ((apid != t->stats.audio_pid || stype != t->stats.audio_stream_type)
            && !t->warned_lock_change) {
            t->warned_lock_change = true;
            rae_logf("ts: PMT no longer agrees on audio pid (%d -> %d) "
                     "after lock — ignored", t->stats.audio_pid, apid);
        }
        return RAE_OK;
    }
    if (apid < 0) {
        if (latm)
            rae_logf("ts: PMT pid %d: audio is LATM/LOAS (stream_type 0x11) "
                     "— unsupported in M0", t->stats.pmt_pid);
        else
            rae_logf("ts: PMT pid %d: no supported audio elementary stream",
                     t->stats.pmt_pid);
        return RAE_E_UNSUPPORTED;
    }
    t->stats.audio_pid = apid;
    t->stats.audio_stream_type = stype;
    rae_logf("ts: locked audio pid %d (stream_type 0x%02X)",
             apid, (unsigned)stype);
    return RAE_OK;
}

/* One payload-carrying packet on the locked audio PID. */
static void ts_audio(rae_ts *t, bool pusi, const uint8_t *pl, size_t n,
                     uint8_t cc)
{
    if (t->prev_cc >= 0) {
        if (cc == (uint8_t)t->prev_cc) {    /* legal duplicate: drop silent  */
            t->stats.dup_packets++;
            return;
        }
        if (cc != ((t->prev_cc + 1) & 0x0F)) {
            t->stats.cc_discontinuities++;  /* torn PES must not reach the   */
            t->pes_state = PES_IDLE;        /* framer: drop to next PUSI     */
            t->phdr_have = t->phdr_need = 0;
        }
    }
    t->prev_cc = cc;

    if (pusi) {
        t->stats.pes_starts++;
        t->pes_state = PES_HDR;             /* abandon any torn header       */
        t->phdr_have = 0;
        t->phdr_need = 9;                   /* fixed part; grows once known  */
    }

    if (t->pes_state == PES_IDLE)
        return;

    if (t->pes_state == PES_HDR) {          /* header may split across pkts  */
        while (n > 0 && t->pes_state == PES_HDR) {
            size_t take = t->phdr_need - t->phdr_have;
            if (take > n)
                take = n;
            memcpy(t->phdr + t->phdr_have, pl, take);
            t->phdr_have += take;
            pl += take;
            n  -= take;
            if (t->phdr_have >= 4 &&
                (t->phdr[0] != 0x00 || t->phdr[1] != 0x00 ||
                 t->phdr[2] != 0x01 ||
                 t->phdr[3] < 0xC0 || t->phdr[3] > 0xDF)) {
                if (!t->warned_bad_pes) {
                    t->warned_bad_pes = true;
                    rae_logf("ts: audio pid %d: bad PES start "
                             "%02X %02X %02X %02X — dropped to next PUSI",
                             t->stats.audio_pid,
                             (unsigned)t->phdr[0], (unsigned)t->phdr[1],
                             (unsigned)t->phdr[2], (unsigned)t->phdr[3]);
                }
                t->pes_state = PES_IDLE;
                t->phdr_have = t->phdr_need = 0;
                return;
            }
            if (t->phdr_have == 9 && t->phdr_need == 9)
                t->phdr_need = 9 + (size_t)t->phdr[8];  /* + header data    */
            if (t->phdr_have == t->phdr_need)
                t->pes_state = PES_BODY;    /* PTS/DTS skipped, by design    */
        }
        if (n == 0)
            return;
    }
    ts_emit(t, pl, n);                      /* PES_BODY: fragment per packet */
}

/* One sync'd 188-byte packet (from pbuf or directly from the chunk). */
static rae_err ts_packet(rae_ts *t, const uint8_t *pkt)
{
    t->stats.packets++;
    if (pkt[1] & 0x80) {                    /* transport_error_indicator     */
        t->stats.error_packets++;
        return RAE_OK;
    }
    const bool    pusi     = (pkt[1] & 0x40) != 0;
    const int     pid      = ((pkt[1] & 0x1F) << 8) | pkt[2];
    const uint8_t scramble = (pkt[3] >> 6) & 0x3;
    const uint8_t afc      = (pkt[3] >> 4) & 0x3;
    const uint8_t cc       = pkt[3] & 0x0F;

    size_t off = 4;
    if (afc & 0x2) {                        /* adaptation field present      */
        off = 5 + (size_t)pkt[4];
        if (off > RAE_TS_PACKET) {
            if (!t->warned_bad_af) {
                t->warned_bad_af = true;
                rae_logf("ts: pid %d: adaptation_field_length %u overruns "
                         "the packet — dropped", pid, (unsigned)pkt[4]);
            }
            return RAE_OK;
        }
    }
    const bool has_payload = (afc & 0x1) != 0 && off < RAE_TS_PACKET;
    const uint8_t *pl = pkt + off;
    const size_t   n  = RAE_TS_PACKET - off;

    if (pid == TS_NULL_PID)
        return RAE_OK;
    if (pid == 0x0000) {                    /* PAT                           */
        if (has_payload)
            ts_pat(t, pusi, pl, n);
        return RAE_OK;
    }
    if (t->stats.pmt_pid >= 0 && pid == t->stats.pmt_pid)
        return has_payload ? ts_pmt(t, pusi, pl, n) : RAE_OK;
    if (t->stats.audio_pid >= 0 && pid == t->stats.audio_pid) {
        t->stats.audio_packets++;
        if (!has_payload)
            return RAE_OK;
        if (scramble != 0) {                /* encrypted ES: never feed the  */
            if (!t->warned_scrambled) {     /* framer ciphertext             */
                t->warned_scrambled = true;
                rae_logf("ts: audio pid %d: scrambled payload "
                         "(transport_scrambling_control %u) — dropped",
                         pid, (unsigned)scramble);
            }
            return RAE_OK;
        }
        ts_audio(t, pusi, pl, n, cc);
    }
    return RAE_OK;                          /* unknown PIDs: ignored         */
}

/* pbuf[0] turned out not to start a real packet: resume the hunt at pbuf[1].
 * Whatever sync byte it finds is itself only provisional — nothing past its
 * 188-byte window has been seen yet.  Called only with a full pbuf. */
static void ts_pbuf_rehunt(rae_ts *t)
{
    size_t j = 1;
    while (j < RAE_TS_PACKET && t->pbuf[j] != TS_SYNC)
        j++;
    ts_sync_loss(t, j);
    t->pbuf_len  = RAE_TS_PACKET - j;
    t->pbuf_prov = t->pbuf_len > 0;
    if (t->pbuf_len > 0)
        memmove(t->pbuf, t->pbuf + j, t->pbuf_len);
}

/* ── public API ───────────────────────────────────────────────────────── */

rae_err rae_ts_create(rae_ts **out, rae_ts_pes_cb cb, void *user)
{
    if (out)
        *out = nullptr;
    if (!out || !cb) {
        rae_logf("ts: create: %s", !out ? "out is null" : "callback is null");
        return RAE_E_INVALID;
    }
    rae_ts *t = calloc(1, sizeof *t);
    if (!t) {
        rae_logf("ts: create: out of memory (%zu bytes)", sizeof *t);
        return RAE_E_OOM;
    }
    t->cb   = cb;
    t->user = user;
    t->prev_cc = -1;
    t->stats.pmt_pid   = -1;
    t->stats.audio_pid = -1;
    t->pes_state = PES_IDLE;
    *out = t;
    return RAE_OK;
}

rae_err rae_ts_feed(rae_ts *t, const uint8_t *chunk, size_t len)
{
    if (!t || (!chunk && len > 0)) {
        rae_logf("ts: feed: invalid arguments");
        return RAE_E_INVALID;
    }
    if (t->in_cb) {
        rae_logf("ts: feed: re-entered from the PES callback — rejected");
        return RAE_E_INVALID;
    }
    if (t->dead)                            /* only destroy/reset are legal  */
        return RAE_E_UNSUPPORTED;

    while (len > 0) {
        if (t->pbuf_len > 0) {              /* packet split across feeds     */
            const size_t need = RAE_TS_PACKET - t->pbuf_len;
            const size_t take = need < len ? need : len;
            memcpy(t->pbuf + t->pbuf_len, chunk, take);
            t->pbuf_len += take;
            chunk += take;
            len   -= take;
            if (t->pbuf_len < RAE_TS_PACKET)
                return RAE_OK;
            if (t->pbuf[0] != TS_SYNC) {    /* defensive: pbuf always starts */
                ts_pbuf_rehunt(t);          /* at an accepted sync byte      */
                continue;
            }
            if (t->pbuf_prov) {
                /* A tail candidate is accepted only provisionally: before
                 * parsing, re-judge it against the byte that FOLLOWS its
                 * 188-byte window (mirrors the in-chunk chunk[i+188]==0x47
                 * plausibility check).  A false 0x47 in garbage must not
                 * fabricate a packet out of real stream bytes. */
                if (len == 0)
                    return RAE_OK;          /* verdict needs the next feed   */
                if (chunk[0] != TS_SYNC) {  /* false sync: hunt on at pbuf[1]*/
                    ts_pbuf_rehunt(t);
                    continue;
                }
                t->pbuf_prov = false;
            }
            t->hunting = false;
            const rae_err e = ts_packet(t, t->pbuf);
            t->pbuf_len = 0;
            if (e != RAE_OK) {
                t->dead = true;
                return e;
            }
            continue;
        }

        if (chunk[0] != TS_SYNC) {          /* sync hunt, byte-wise          */
            size_t i = 1;
            while (i < len) {
                /* plausible sync: 0x47 with 0x47 again 188 bytes later when
                 * enough data is buffered to check; a tail candidate is
                 * accepted provisionally (pbuf_prov) and re-judged once the
                 * byte after its 188-byte window arrives. */
                if (chunk[i] == TS_SYNC &&
                    (i + RAE_TS_PACKET >= len ||
                     chunk[i + RAE_TS_PACKET] == TS_SYNC))
                    break;
                i++;
            }
            ts_sync_loss(t, i);
            chunk += i;
            len   -= i;
            continue;
        }
        if (t->hunting && len <= RAE_TS_PACKET) {
            /* candidate adopted mid-hunt with nothing visible past its
             * 188-byte window: buffer it provisionally — it must not reach
             * ts_packet until the follow-up byte is judged (pbuf_prov). */
            memcpy(t->pbuf, chunk, len);
            t->pbuf_len  = len;
            t->pbuf_prov = true;
            return RAE_OK;
        }
        if (t->hunting && chunk[RAE_TS_PACKET] != TS_SYNC) {
            ts_sync_loss(t, 1);             /* false candidate: hunt on      */
            chunk += 1;
            len   -= 1;
            continue;
        }
        t->hunting = false;
        if (len < RAE_TS_PACKET) {          /* buffer the partial tail       */
            memcpy(t->pbuf, chunk, len);
            t->pbuf_len = len;
            return RAE_OK;
        }
        const rae_err e = ts_packet(t, chunk);   /* zero-copy fast path      */
        if (e != RAE_OK) {
            t->dead = true;
            return e;
        }
        chunk += RAE_TS_PACKET;
        len   -= RAE_TS_PACKET;
    }
    return RAE_OK;
}

void rae_ts_flush(rae_ts *t)
{
    if (!t)
        return;
    if (t->in_cb) {
        rae_logf("ts: flush: called from the PES callback — ignored");
        return;
    }
    t->pbuf_len  = 0;
    t->pbuf_prov = false;
    t->hunting   = false;
    if (t->pes_state == PES_HDR)            /* rest of that header is gone   */
        t->pes_state = PES_IDLE;
    t->phdr_have = t->phdr_need = 0;
    /* PAT/PMT lock, CC state and an open PES_BODY are RETAINED: consecutive
     * segments of one variant are a continuous transport stream.            */
}

void rae_ts_reset(rae_ts *t)
{
    if (!t)
        return;
    if (t->in_cb) {
        rae_logf("ts: reset: called from the PES callback — ignored");
        return;
    }
    t->pbuf_len  = 0;
    t->pbuf_prov = false;
    t->hunting   = false;
    t->pes_state = PES_IDLE;
    t->phdr_have = t->phdr_need = 0;
    t->prev_cc   = -1;
    t->stats.pmt_pid   = -1;                /* lock forgotten; counters kept */
    t->stats.audio_pid = -1;
    t->stats.audio_stream_type = 0;
    t->dead = false;
}

const rae_ts_stats *rae_ts_get_stats(const rae_ts *t)
{
    return t ? &t->stats : nullptr;
}

void rae_ts_destroy(rae_ts *t)
{
    free(t);                                /* free(nullptr) is a no-op      */
}
