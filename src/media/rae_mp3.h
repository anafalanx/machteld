/* Incremental minimp3 decoder. Adapted from Rae (MIT), see licenses/rae.txt. */
#ifndef RAE_MP3_H
#define RAE_MP3_H

#include "rae_common.h"

#define RAE_MP3_BUF_MAX (256u * 1024)  /* accumulator cap; reaching it with no
                                          decodable frame ⇒ RAE_E_FORMAT     */

typedef struct rae_mp3 rae_mp3;         /* opaque; owned by rae_mp3.c */
size_t rae_mp3_pending(const rae_mp3 *m);

rae_err rae_mp3_create(rae_mp3 **out);              /* RAE_E_OOM            */
void    rae_mp3_destroy(rae_mp3 *m);

/* Drop buffered bytes and decoder state (reconnect).  mp3dec_init anew. */
void    rae_mp3_reset(rae_mp3 *m);

/* Append raw stream bytes (any chunking).  RAE_OK / RAE_E_OOM /
 * RAE_E_FORMAT (accumulator full and still no frame — hopeless stream).     */
rae_err rae_mp3_feed(rae_mp3 *m, const uint8_t *bytes, size_t len);

/* Decode at most one MP3 frame.
 *   RAE_OK, *out_floats > 0 : *samples = interleaved float32 (borrowed,
 *       valid until next call); *sample_rate / *channels describe them.
 *   RAE_OK, *out_floats == 0: need more input.
 * Pattern (identical to rae_aac):
 *   feed(chunk); while (pull(...), *out_floats > 0) consume;                */
rae_err rae_mp3_pull(rae_mp3 *m, const float **samples, size_t *out_floats,
                     int *sample_rate, int *channels);

#endif /* RAE_MP3_H */
