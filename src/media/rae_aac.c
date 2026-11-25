/* Windows Media Foundation AAC and HE-AAC decoder. Adapted from Rae (MIT), see licenses/rae.txt. */
#include "rae_common.h"

#include <objbase.h>
#include <mfapi.h>
#include <mftransform.h>
#include <mferror.h>

#include <stdlib.h>
#include <string.h>

#include "rae_adts.h"
#include "rae_aac.h"
#include "foundation.h"

#define AAC_OUT_MIN_BYTES   (64u * 1024u)   /* output buffer floor (contract) */
#define AAC_IN_MAX_BYTES    (1u << 20)      /* sanity cap; ADTS max is 8191   */
#define AAC_MAX_RENEGOTIATE 4               /* STREAM_CHANGE loops per pull   */

struct rae_aac {
    IMFTransform   *mft;
    IMFSample      *in_sample;      /* reused; frame bytes copied in       */
    IMFMediaBuffer *in_buf;
    DWORD           in_cap;
    IMFSample      *out_sample;     /* reused; NULL if MFT provides samples */
    IMFMediaBuffer *out_buf;
    DWORD           out_cap;
    bool            mft_provides;   /* MFT_OUTPUT_STREAM_PROVIDES_SAMPLES   */
    bool            out_is_float;   /* else PCM16, converted on the way out */
    int             out_sr;         /* authoritative: from the SET output   */
    int             out_ch;         /*   type, not the ADTS header          */
    float          *fbuf;           /* converted output; grows, then steady */
    size_t          fbuf_cap;       /* capacity in floats                   */
};

/* ── float output buffer ──────────────────────────────────────────────── */

static rae_err aac_fbuf_reserve(rae_aac *d, size_t nfloats) {
    if (nfloats <= d->fbuf_cap)
        return RAE_OK;
    size_t cap = d->fbuf_cap ? d->fbuf_cap : 4096;
    while (cap < nfloats)
        cap *= 2;
    float *nb = realloc(d->fbuf, cap * sizeof(float));
    if (!nb) {
        rae_logf("aac: out of memory growing float buffer to %zu floats", cap);
        return RAE_E_OOM;
    }
    d->fbuf = nb;
    d->fbuf_cap = cap;
    return RAE_OK;
}

/* ── input media type (ladder rungs a/b) ──────────────────────────────── */

static HRESULT aac_build_input_type(int sr, int ch, int aot, bool with_blob,
                                    IMFMediaType **out_t) {
    IMFMediaType *t = NULL;
    HRESULT hr = media_type(&t);
    if (FAILED(hr))
        return hr;
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(t, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetGUID(t, &MF_MT_SUBTYPE, &MFAudioFormat_AAC);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(t, &MF_MT_AUDIO_SAMPLES_PER_SECOND, (UINT32)sr);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(t, &MF_MT_AUDIO_NUM_CHANNELS, (UINT32)ch);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(t, &MF_MT_AAC_PAYLOAD_TYPE, 1);
    if (SUCCEEDED(hr)) hr = IMFMediaType_SetUINT32(t, &MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0xFE);
    if (SUCCEEDED(hr) && with_blob) {
        /* HEAACWAVEINFO tail (12 bytes, little-endian) + 2-byte ASC.
         * freq index was validated >= 0 in rae_aac_create.               */
        int fi = rae_adts_freq_index(sr);
        uint8_t blob[14] = {0};
        blob[0]  = 1;                                       /* wPayloadType = ADTS  */
        blob[2]  = 0xFE;                                    /* wAudioProfileLevelIndication */
        blob[12] = (uint8_t)((aot << 3) | (fi >> 1));
        blob[13] = (uint8_t)(((fi & 1) << 7) | (ch << 3));
        hr = IMFMediaType_SetBlob(t, &MF_MT_USER_DATA, blob, (UINT32)sizeof blob);
    }
    if (FAILED(hr)) {
        IMFMediaType_Release(t);
        return hr;
    }
    *out_t = t;
    return S_OK;
}

/* The binding ladder from rae_aac.h: (a) ADTS + USER_DATA, (b) without,
 * (c) enumerate the MFT's own AAC types.  Logs which rung won.            */
static rae_err aac_set_input_type(rae_aac *d, int sr, int ch, int aot) {
    IMFMediaType *t = NULL;
    HRESULT hr = aac_build_input_type(sr, ch, aot, true, &t);
    if (SUCCEEDED(hr)) {
        hr = IMFTransform_SetInputType(d->mft, 0, t, 0);
        IMFMediaType_Release(t);
        if (SUCCEEDED(hr)) {
            rae_logf("aac: input type set (ADTS + HEAACWAVEINFO user data, %d Hz x %d aot %d)",
                     sr, ch, aot);
            return RAE_OK;
        }
    }

    t = NULL;
    hr = aac_build_input_type(sr, ch, aot, false, &t);
    if (SUCCEEDED(hr)) {
        hr = IMFTransform_SetInputType(d->mft, 0, t, 0);
        IMFMediaType_Release(t);
        if (SUCCEEDED(hr)) {
            rae_logf("aac: input type set (ADTS, no user data, %d Hz x %d)", sr, ch);
            return RAE_OK;
        }
    }

    for (DWORD i = 0;; i++) {
        t = NULL;
        hr = IMFTransform_GetInputAvailableType(d->mft, 0, i, &t);
        if (hr == MF_E_NO_MORE_TYPES || FAILED(hr))
            break;
        GUID sub = {0};
        if (SUCCEEDED(IMFMediaType_GetGUID(t, &MF_MT_SUBTYPE, &sub)) &&
            IsEqualGUID(&sub, &MFAudioFormat_AAC)) {
            HRESULT sh = IMFMediaType_SetUINT32(t, &MF_MT_AUDIO_SAMPLES_PER_SECOND, (UINT32)sr);
            if (SUCCEEDED(sh)) sh = IMFMediaType_SetUINT32(t, &MF_MT_AUDIO_NUM_CHANNELS, (UINT32)ch);
            if (SUCCEEDED(sh)) sh = IMFMediaType_SetUINT32(t, &MF_MT_AAC_PAYLOAD_TYPE, 1);
            if (SUCCEEDED(sh)) sh = IMFTransform_SetInputType(d->mft, 0, t, 0);
            if (SUCCEEDED(sh)) {
                IMFMediaType_Release(t);
                rae_logf("aac: input type set (enumerated MFT type %lu, %d Hz x %d)",
                         (unsigned long)i, sr, ch);
                return RAE_OK;
            }
        }
        IMFMediaType_Release(t);
    }

    rae_logf("aac: no acceptable AAC input type (sr=%d ch=%d aot=%d, last hr=0x%08lX)",
             sr, ch, aot, (unsigned long)hr);
    return RAE_E_DECODER;
}

/* ── output negotiation + the reusable output sample ──────────────────── */

static rae_err aac_ensure_out_sample(rae_aac *d, const MFT_OUTPUT_STREAM_INFO *osi) {
    if (d->mft_provides) {
        /* MFT allocates; drop ours if a previous negotiation made one.   */
        if (d->out_buf) {
            if (d->out_sample)
                (void)IMFSample_RemoveAllBuffers(d->out_sample);
            IMFMediaBuffer_Release(d->out_buf);
            d->out_buf = NULL;
            d->out_cap = 0;
        }
        if (d->out_sample) {
            IMFSample_Release(d->out_sample);
            d->out_sample = NULL;
        }
        return RAE_OK;
    }

    DWORD need = osi->cbSize > AAC_OUT_MIN_BYTES ? osi->cbSize : AAC_OUT_MIN_BYTES;
    if (!d->out_sample) {
        HRESULT hr = media_sample(&d->out_sample);
        if (FAILED(hr)) {
            rae_logf("aac: MFCreateSample (output) failed (hr=0x%08lX)", (unsigned long)hr);
            return RAE_E_OOM;
        }
    }
    if (d->out_buf && d->out_cap < need) {
        (void)IMFSample_RemoveAllBuffers(d->out_sample);
        IMFMediaBuffer_Release(d->out_buf);
        d->out_buf = NULL;
        d->out_cap = 0;
    }
    if (!d->out_buf) {
        HRESULT hr;
        if (osi->cbAlignment > 1)
            hr = media_aligned_buffer(need, osi->cbAlignment - 1, &d->out_buf);
        else
            hr = media_buffer(need, &d->out_buf);
        if (FAILED(hr)) {
            rae_logf("aac: output buffer alloc failed (%lu bytes, hr=0x%08lX)",
                     (unsigned long)need, (unsigned long)hr);
            d->out_buf = NULL;
            return RAE_E_OOM;
        }
        hr = IMFSample_AddBuffer(d->out_sample, d->out_buf);
        if (FAILED(hr)) {
            rae_logf("aac: IMFSample_AddBuffer (output) failed (hr=0x%08lX)", (unsigned long)hr);
            IMFMediaBuffer_Release(d->out_buf);
            d->out_buf = NULL;
            return RAE_E_DECODER;
        }
        d->out_cap = need;
    }
    return RAE_OK;
}

/* Enumerate output types, prefer Float, accept PCM16; SetOutputType; read
 * the authoritative sr/ch back from the SET type (HE-AAC SBR doubling shows
 * up here, never in the ADTS header).  Called at create and again on every
 * MF_E_TRANSFORM_STREAM_CHANGE.                                            */
static rae_err aac_negotiate_output(rae_aac *d) {
    IMFMediaType *best = NULL;
    bool best_float = false;
    HRESULT hr = S_OK;

    for (DWORD i = 0;; i++) {
        IMFMediaType *t = NULL;
        hr = IMFTransform_GetOutputAvailableType(d->mft, 0, i, &t);
        if (hr == MF_E_NO_MORE_TYPES)
            break;
        if (FAILED(hr)) {
            if (best)
                IMFMediaType_Release(best);
            rae_logf("aac: GetOutputAvailableType(%lu) failed (hr=0x%08lX)",
                     (unsigned long)i, (unsigned long)hr);
            return RAE_E_DECODER;
        }
        GUID sub = {0};
        HRESULT gh = IMFMediaType_GetGUID(t, &MF_MT_SUBTYPE, &sub);
        if (SUCCEEDED(gh) && IsEqualGUID(&sub, &MFAudioFormat_Float)) {
            if (best)
                IMFMediaType_Release(best);
            best = t;
            best_float = true;
            break;                              /* preferred — stop looking */
        }
        if (SUCCEEDED(gh) && IsEqualGUID(&sub, &MFAudioFormat_PCM) && !best) {
            UINT32 bits = 0;
            HRESULT bh = IMFMediaType_GetUINT32(t, &MF_MT_AUDIO_BITS_PER_SAMPLE, &bits);
            if (FAILED(bh) || bits == 16) {     /* absent attr ⇒ assume 16  */
                best = t;                       /* hold; keep hunting Float */
                best_float = false;
                continue;
            }
        }
        IMFMediaType_Release(t);
    }
    if (!best) {
        rae_logf("aac: no Float or 16-bit PCM output type offered by the MFT");
        return RAE_E_DECODER;
    }

    hr = IMFTransform_SetOutputType(d->mft, 0, best, 0);
    if (FAILED(hr)) {
        IMFMediaType_Release(best);
        rae_logf("aac: SetOutputType failed (hr=0x%08lX)", (unsigned long)hr);
        return RAE_E_DECODER;
    }
    UINT32 sr = 0, ch = 0;
    hr = IMFMediaType_GetUINT32(best, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &sr);
    if (SUCCEEDED(hr))
        hr = IMFMediaType_GetUINT32(best, &MF_MT_AUDIO_NUM_CHANNELS, &ch);
    IMFMediaType_Release(best);
    if (FAILED(hr) || sr == 0 || ch == 0) {
        rae_logf("aac: output type missing sr/ch (hr=0x%08lX sr=%u ch=%u)",
                 (unsigned long)hr, (unsigned)sr, (unsigned)ch);
        return RAE_E_DECODER;
    }
    d->out_sr = (int)sr;
    d->out_ch = (int)ch;
    d->out_is_float = best_float;

    MFT_OUTPUT_STREAM_INFO osi = {0};
    hr = IMFTransform_GetOutputStreamInfo(d->mft, 0, &osi);
    if (FAILED(hr)) {
        rae_logf("aac: GetOutputStreamInfo failed (hr=0x%08lX)", (unsigned long)hr);
        return RAE_E_DECODER;
    }
    d->mft_provides = (osi.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;

    rae_err e = aac_ensure_out_sample(d, &osi);
    if (e != RAE_OK)
        return e;

    rae_logf("aac: output %d Hz x %d ch, %s%s", d->out_sr, d->out_ch,
             d->out_is_float ? "float32" : "pcm16->float32",
             d->mft_provides ? " (MFT-provided samples)" : "");
    return RAE_OK;
}

static rae_err aac_send_streaming_notifies(rae_aac *d) {
    HRESULT hr = IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    if (FAILED(hr)) {
        rae_logf("aac: NOTIFY_BEGIN_STREAMING failed (hr=0x%08lX)", (unsigned long)hr);
        return RAE_E_DECODER;
    }
    hr = IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    if (FAILED(hr)) {
        rae_logf("aac: NOTIFY_START_OF_STREAM failed (hr=0x%08lX)", (unsigned long)hr);
        return RAE_E_DECODER;
    }
    return RAE_OK;
}

/* ── public API ───────────────────────────────────────────────────────── */

rae_err rae_aac_create(rae_aac **out, int sample_rate, int channels, int aot) {
    if (!out) {
        rae_logf("aac: create: out is NULL");
        return RAE_E_INVALID;
    }
    *out = NULL;
    if (channels < 1 || channels > 7 || aot < 1 || aot > 31) {
        rae_logf("aac: create: bad arguments (channels=%d aot=%d)", channels, aot);
        return RAE_E_INVALID;
    }
    if (rae_adts_freq_index(sample_rate) < 0) {
        rae_logf("aac: create: sample rate %d has no ADTS frequency index", sample_rate);
        return RAE_E_INVALID;
    }

    rae_aac *d = calloc(1, sizeof *d);
    if (!d) {
        rae_logf("aac: create: out of memory");
        return RAE_E_OOM;
    }

    HRESULT hr = CoCreateInstance(&CLSID_CMSAACDecMFT, NULL, CLSCTX_INPROC_SERVER,
                                  &IID_IMFTransform, (void **)&d->mft);
    if (FAILED(hr)) {
        rae_logf("aac: AAC decoder MFT unavailable — install the Media Feature Pack "
                 "(CoCreateInstance hr=0x%08lX)", (unsigned long)hr);
        free(d);
        return RAE_E_DECODER;
    }

    rae_err e = aac_set_input_type(d, sample_rate, channels, aot);
    if (e == RAE_OK)
        e = aac_negotiate_output(d);

    if (e == RAE_OK) {
        hr = media_sample(&d->in_sample);
        if (SUCCEEDED(hr))
            hr = media_buffer(RAE_ADTS_MAX_FRAME, &d->in_buf);
        if (SUCCEEDED(hr))
            hr = IMFSample_AddBuffer(d->in_sample, d->in_buf);
        if (FAILED(hr)) {
            rae_logf("aac: input sample/buffer creation failed (hr=0x%08lX)",
                     (unsigned long)hr);
            e = RAE_E_OOM;
        } else {
            d->in_cap = RAE_ADTS_MAX_FRAME;
        }
    }

    if (e == RAE_OK)
        e = aac_send_streaming_notifies(d);

    if (e != RAE_OK) {
        rae_aac_destroy(d);
        return e;
    }
    *out = d;
    return RAE_OK;
}

rae_err rae_aac_feed(rae_aac *d, const uint8_t *adts_frame, size_t len) {
    if (!d || !adts_frame || len == 0 || len > AAC_IN_MAX_BYTES) {
        rae_logf("aac: feed: invalid argument (frame=%p len=%zu)",
                 (const void *)adts_frame, len);
        return RAE_E_INVALID;
    }
    if (!d->in_buf) {                       /* a previous grow failed hard */
        rae_logf("aac: feed: input buffer lost by an earlier failure");
        return RAE_E_DECODER;
    }

    if ((DWORD)len > d->in_cap) {           /* dead in practice: ADTS <= 8191 */
        DWORD ncap = d->in_cap;
        while (ncap < (DWORD)len)
            ncap *= 2;
        IMFMediaBuffer *nb = NULL;
        HRESULT ghr = media_buffer(ncap, &nb);
        if (FAILED(ghr)) {
            rae_logf("aac: input buffer grow to %lu failed (hr=0x%08lX)",
                     (unsigned long)ncap, (unsigned long)ghr);
            return RAE_E_OOM;
        }
        (void)IMFSample_RemoveAllBuffers(d->in_sample);
        IMFMediaBuffer_Release(d->in_buf);
        d->in_buf = NULL;
        d->in_cap = 0;
        ghr = IMFSample_AddBuffer(d->in_sample, nb);
        if (FAILED(ghr)) {
            rae_logf("aac: IMFSample_AddBuffer (input grow) failed (hr=0x%08lX)",
                     (unsigned long)ghr);
            IMFMediaBuffer_Release(nb);
            return RAE_E_DECODER;
        }
        d->in_buf = nb;
        d->in_cap = ncap;
    }

    BYTE *p = NULL;
    DWORD maxlen = 0;
    HRESULT hr = IMFMediaBuffer_Lock(d->in_buf, &p, &maxlen, NULL);
    if (FAILED(hr)) {
        rae_logf("aac: input buffer Lock failed (hr=0x%08lX)", (unsigned long)hr);
        return RAE_E_DECODER;
    }
    memcpy(p, adts_frame, len);
    (void)IMFMediaBuffer_Unlock(d->in_buf);   /* cannot meaningfully fail */
    hr = IMFMediaBuffer_SetCurrentLength(d->in_buf, (DWORD)len);
    if (FAILED(hr)) {
        rae_logf("aac: SetCurrentLength(%zu) failed (hr=0x%08lX)", len, (unsigned long)hr);
        return RAE_E_DECODER;
    }

    hr = IMFTransform_ProcessInput(d->mft, 0, d->in_sample, 0);
    if (hr == MF_E_NOTACCEPTING) {
        rae_logf("aac: ProcessInput MF_E_NOTACCEPTING — caller must pull until "
                 "empty after every feed (calling discipline broken)");
        return RAE_E_INVALID;
    }
    if (FAILED(hr)) {
        rae_logf("aac: ProcessInput failed (hr=0x%08lX, len=%zu)", (unsigned long)hr, len);
        return RAE_E_DECODER;
    }
    return RAE_OK;
}

rae_err rae_aac_pull(rae_aac *d, const float **samples, size_t *out_floats,
                     int *sample_rate, int *channels) {
    if (!d || !samples || !out_floats || !sample_rate || !channels) {
        rae_logf("aac: pull: invalid argument");
        return RAE_E_INVALID;
    }
    *samples = NULL;
    *out_floats = 0;
    *sample_rate = d->out_sr;
    *channels = d->out_ch;

    for (int renegs = 0; renegs <= AAC_MAX_RENEGOTIATE; renegs++) {
        MFT_OUTPUT_DATA_BUFFER ob;
        memset(&ob, 0, sizeof ob);
        ob.dwStreamID = 0;
        ob.pSample = d->mft_provides ? NULL : d->out_sample;
        DWORD status = 0;

        HRESULT hr = IMFTransform_ProcessOutput(d->mft, 0, 1, &ob, &status);
        if (ob.pEvents) {
            IMFCollection_Release(ob.pEvents);
            ob.pEvents = NULL;
        }

        if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT)
            return RAE_OK;                          /* *out_floats == 0     */

        if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
            if (d->mft_provides && ob.pSample)
                IMFSample_Release(ob.pSample);
            rae_logf("aac: output stream change (was %d Hz x %d) — renegotiating",
                     d->out_sr, d->out_ch);
            rae_err e = aac_negotiate_output(d);    /* logs the new format  */
            if (e != RAE_OK)
                return e;
            *sample_rate = d->out_sr;
            *channels = d->out_ch;
            continue;                               /* retry this same pull */
        }

        if (FAILED(hr)) {
            rae_logf("aac: ProcessOutput failed (hr=0x%08lX)", (unsigned long)hr);
            return RAE_E_DECODER;
        }

        IMFSample *smp = ob.pSample;
        if (!smp) {
            rae_logf("aac: ProcessOutput returned S_OK with no sample");
            return RAE_E_DECODER;
        }

        /* Single-buffer sample ⇒ this AddRefs the existing buffer, no copy. */
        IMFMediaBuffer *buf = NULL;
        hr = IMFSample_ConvertToContiguousBuffer(smp, &buf);
        if (FAILED(hr)) {
            rae_logf("aac: ConvertToContiguousBuffer failed (hr=0x%08lX)", (unsigned long)hr);
            if (d->mft_provides)
                IMFSample_Release(smp);
            return RAE_E_DECODER;
        }

        BYTE *p = NULL;
        DWORD cb = 0;
        hr = IMFMediaBuffer_Lock(buf, &p, NULL, &cb);
        if (FAILED(hr)) {
            rae_logf("aac: output buffer Lock failed (hr=0x%08lX)", (unsigned long)hr);
            IMFMediaBuffer_Release(buf);
            if (d->mft_provides)
                IMFSample_Release(smp);
            return RAE_E_DECODER;
        }

        size_t n = d->out_is_float ? cb / 4u : cb / 2u;
        rae_err e = aac_fbuf_reserve(d, n ? n : 1);
        if (e == RAE_OK && n > 0) {
            if (d->out_is_float) {
                memcpy(d->fbuf, p, n * sizeof(float));
            } else {
                const int16_t *src = (const int16_t *)(const void *)p;
                for (size_t k = 0; k < n; k++)
                    d->fbuf[k] = (float)src[k] / 32768.0f;
            }
        }

        (void)IMFMediaBuffer_Unlock(buf);
        IMFMediaBuffer_Release(buf);
        if (d->mft_provides)
            IMFSample_Release(smp);
        else                                    /* hygiene for the reuse    */
            (void)IMFMediaBuffer_SetCurrentLength(d->out_buf, 0);

        if (e != RAE_OK)
            return e;

        *samples = d->fbuf;
        *out_floats = n;
        *sample_rate = d->out_sr;
        *channels = d->out_ch;
        return RAE_OK;
    }

    rae_logf("aac: ProcessOutput kept signaling stream change after %d renegotiations",
             AAC_MAX_RENEGOTIATE);
    return RAE_E_DECODER;
}

void rae_aac_flush(rae_aac *d) {
    if (!d)
        return;
    HRESULT hr = IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_COMMAND_FLUSH, 0);
    if (FAILED(hr))
        rae_logf("aac: COMMAND_FLUSH failed (hr=0x%08lX)", (unsigned long)hr);
    /* Re-prime so the next feed just works (header contract). */
    (void)aac_send_streaming_notifies(d);
}

rae_err rae_aac_drain(rae_aac *d) {
    if (!d) {
        rae_logf("aac: drain: d is NULL");
        return RAE_E_INVALID;
    }
    HRESULT hr = IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_COMMAND_DRAIN, 0);
    if (FAILED(hr)) {
        rae_logf("aac: COMMAND_DRAIN failed (hr=0x%08lX)", (unsigned long)hr);
        return RAE_E_DECODER;
    }
    return RAE_OK;
}

void rae_aac_destroy(rae_aac *d) {
    if (!d)
        return;
    if (d->in_buf)
        IMFMediaBuffer_Release(d->in_buf);
    if (d->in_sample)
        IMFSample_Release(d->in_sample);
    if (d->out_buf)
        IMFMediaBuffer_Release(d->out_buf);
    if (d->out_sample)
        IMFSample_Release(d->out_sample);
    if (d->mft)
        IMFTransform_Release(d->mft);
    free(d->fbuf);
    free(d);
}
