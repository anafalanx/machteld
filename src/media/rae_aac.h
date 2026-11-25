/* Windows Media Foundation AAC and HE-AAC decoder. Adapted from Rae (MIT), see licenses/rae.txt. */
#ifndef RAE_AAC_H
#define RAE_AAC_H

#include "rae_common.h"

/* Materialized in rae_guids.c; declared here so no TU needs <wmcodecdsp.h>.
 * {32D186A7-218F-4C75-8876-DD77273A8999}                                    */
extern const GUID CLSID_CMSAACDecMFT;

typedef struct rae_aac rae_aac;         /* opaque; owned by rae_aac.c */

/* sample_rate/channels/aot from the first ADTS frame (rae_adts_frame fields
 * sample_rate/channels/profile).  channels must be 1..7 (callers reject 0
 * before getting here).  Errors: RAE_E_DECODER (MFT missing or type ladder
 * exhausted — already logged precisely), RAE_E_OOM, RAE_E_INVALID.          */
rae_err rae_aac_create(rae_aac **out, int sample_rate, int channels, int aot);

/* One whole ADTS frame, header included.  RAE_OK / RAE_E_DECODER /
 * RAE_E_INVALID (calling discipline broken) / RAE_E_OOM.                    */
rae_err rae_aac_feed(rae_aac *d, const uint8_t *adts_frame, size_t len);

/* Pull decoded audio.
 *   RAE_OK, *out_floats > 0 : *samples = interleaved float32 in the
 *       wrapper's internal buffer — BORROWED, valid until the next call of
 *       any rae_aac function on this instance.  *sample_rate / *channels
 *       describe THESE samples; CALLERS MUST CHECK THEM EVERY PULL (format
 *       changes mid-stream are normal for HE-AAC).
 *   RAE_OK, *out_floats == 0: decoder wants more input (feed the next frame).
 *   RAE_E_DECODER           : hard failure (logged).                        */
rae_err rae_aac_pull(rae_aac *d, const float **samples, size_t *out_floats,
                     int *sample_rate, int *channels);

/* MFT_MESSAGE_COMMAND_FLUSH: drop all in-flight data (reconnect, HLS
 * discontinuity, live-edge jump).  Streaming notifies are re-sent so the
 * next feed just works.                                                     */
void rae_aac_flush(rae_aac *d);

/* MFT_MESSAGE_COMMAND_DRAIN: squeeze out the tail; after drain, keep calling
 * rae_aac_pull until *out_floats == 0.  (M0 uses this only in tests; user
 * stop is immediate and skips draining.)                                    */
rae_err rae_aac_drain(rae_aac *d);

void rae_aac_destroy(rae_aac *d);

#endif /* RAE_AAC_H */
