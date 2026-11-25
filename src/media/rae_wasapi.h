/* Windows shared-mode PCM output. Adapted from Rae (MIT), see licenses/rae.txt. */
#ifndef RAE_WASAPI_H
#define RAE_WASAPI_H

#include "rae_common.h"
#include "rae_ring.h"

#define RAE_WASAPI_BUFFER_HNS 2000000   /* ~200 ms device buffer (100-ns units) */

typedef struct rae_wasapi rae_wasapi;   /* opaque; owned by rae_wasapi.c */

/* ring: BORROWED — owned, init'ed and freed by the tuner; must outlive this
 * sink (tuner frees it only after rae_wasapi_close).  sample_rate/channels
 * must match what the producer pushes.  RAE_E_AUDIO / RAE_E_OOM /
 * RAE_E_INVALID.                                                            */
rae_err  rae_wasapi_open(rae_wasapi **out, int sample_rate, int channels,
                         rae_ring *ring);

rae_err  rae_wasapi_start(rae_wasapi *w);   /* pre-roll + IAudioClient::Start */
void     rae_wasapi_stop(rae_wasapi *w);    /* IAudioClient::Stop (optional)  */

/* Join render and release the endpoint, on its dedicated MTA owner. */
bool     rae_wasapi_close(rae_wasapi *w);

/* Atomic counters, readable from any thread.
 * underruns: short-pull events while started (CLI exit 5 if > 0).
 * frames_rendered: total device frames written (incl. zero-filled).
 * device_error: first failing HRESULT the render thread saw (0 = healthy).
 *   Nonzero means the endpoint is dead and nothing renders anymore — the
 *   tuner must end the run with RAE_E_AUDIO, never stall on a full ring.    */
uint64_t rae_wasapi_underruns(const rae_wasapi *w);
bool rae_wasapi_finished(const rae_wasapi *w, uint64_t frames);
uint64_t rae_wasapi_frames_rendered(const rae_wasapi *w);
uint32_t rae_wasapi_device_error(const rae_wasapi *w);

#endif /* RAE_WASAPI_H */
