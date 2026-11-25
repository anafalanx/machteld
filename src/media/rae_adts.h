/* ADTS frame reader. Adapted from Rae (MIT), see licenses/rae.txt. */
#ifndef RAE_ADTS_H
#define RAE_ADTS_H

#include "rae_common.h"

#define RAE_ADTS_MAX_FRAME 8192    /* 13-bit length field ⇒ ≤ 8191 bytes     */

typedef struct rae_adts_frame {
    const uint8_t *data;    /* BORROWED: points into the framer's buffer;
                               valid only until the NEXT call of any rae_adts
                               function on this instance — consume (copy /
                               ProcessInput) immediately                     */
    size_t len;             /* whole frame incl. header (+CRC if present)    */
    int    sample_rate;     /* from sampling_frequency_index (header truth)  */
    int    channels;        /* channel_configuration, 0–7                    */
    int    profile;         /* Audio Object Type: 2 = AAC-LC                 */
} rae_adts_frame;

typedef struct rae_adts rae_adts;       /* opaque; owned by rae_adts.c */
size_t rae_adts_pending(const rae_adts *a);
void rae_adts_finish(rae_adts *a);

rae_err rae_adts_create(rae_adts **out);            /* RAE_E_OOM            */
void    rae_adts_destroy(rae_adts *a);

/* Drop all buffered bytes and the sync lock (HLS discontinuity / reconnect).
 * Counters are kept (per-instance lifetime).                                */
void    rae_adts_reset(rae_adts *a);

/* Append bytes.  RAE_OK or RAE_E_OOM.  Never fails on garbage — resync is
 * internal and unbounded.                                                   */
rae_err rae_adts_feed(rae_adts *a, const uint8_t *bytes, size_t len);

/* Iterate: true ⇒ *out describes the next complete frame (and the framer
 * advanced past it); false ⇒ no complete frame buffered (feed more).  The
 * usage pattern is always:  feed(chunk); while (next(&f)) consume(&f);      */
bool    rae_adts_next(rae_adts *a, rae_adts_frame *out);

/* Lifetime counters (for --probe-ts and logs). */
uint64_t rae_adts_frames_emitted(const rae_adts *a);
uint64_t rae_adts_resyncs(const rae_adts *a);

/* Helper: sample rate → ADTS sampling_frequency_index (0–12), or -1.
 * (96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,
 *  7350).  Exported for rae_aac.c, which needs the index to build the
 * AudioSpecificConfig.                                                      */
int rae_adts_freq_index(int sample_rate);

#endif /* RAE_ADTS_H */
