/* Windows shared-mode PCM output. Adapted from Rae (MIT), see licenses/rae.txt. */

#include "rae_common.h"
#include "rae_ring.h"
#include "rae_wasapi.h"

#include <objbase.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <process.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* KSDATAFORMAT_SUBTYPE_IEEE_FLOAT by value (per rae_wasapi.h: do NOT include
 * <ksmedia.h> and gamble on its link-time presence). */
static const GUID rae_subtype_ieee_float =
    { 0x00000003, 0x0000, 0x0010,
      { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

struct rae_wasapi {
    IAudioClient       *client;
    IAudioRenderClient *render;
    HANDLE              audio_event;      /* auto-reset; signaled by the engine */
    HANDLE              shutdown_event;   /* manual-reset; signaled by close    */
    HANDLE              thread;           /* render thread (_beginthreadex)     */
    UINT32              buffer_frames;    /* device buffer size in frames       */
    int                 sample_rate;
    int                 channels;
    rae_ring           *ring;             /* BORROWED — tuner owns and outlives */
    _Atomic uint64_t    underruns;        /* short-pull events while started    */
    _Atomic uint64_t    frames_rendered;  /* device frames written, incl. zero  */
    _Atomic uint32_t    device_error;     /* first failing HRESULT; 0 = healthy */
    _Atomic bool        started;          /* between start() and stop()/close() */
    _Atomic uint64_t    input_frames, last_input_end, played_position;
};

/* ── Render thread ──────────────────────────────────────────────────────────
 * Parked on {audio_event, shutdown_event}; no events fire before Start.  A
 * device-level HRESULT failure mid-loop (e.g. AUDCLNT_E_DEVICE_INVALIDATED —
 * M0 has no device-change handling) is logged ONCE, latched into
 * device_error (rae_wasapi_device_error — the tuner ends the run with
 * RAE_E_AUDIO), and the thread keeps parking so close() can still join it. */
static unsigned __stdcall rae_wasapi_render_thread(void *arg)
{
    rae_wasapi *w = (rae_wasapi *)arg;

    HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(co))
        rae_logf("wasapi: render thread CoInitializeEx failed (hr=0x%08lX) — continuing",
                 (unsigned long)co);

    DWORD  task_index = 0;
    HANDLE mmcss = AvSetMmThreadCharacteristicsW(L"Audio", &task_index);
    if (mmcss == NULL)
        rae_logf("wasapi: AvSetMmThreadCharacteristicsW failed (error %lu) — no MMCSS boost",
                 GetLastError());

    HANDLE events[2] = { w->audio_event, w->shutdown_event };
    bool   dev_failed = false;            /* log device failure once, not per event */

    for (;;) {
        DWORD wr = WaitForMultipleObjects(2, events, FALSE, INFINITE);
        if (wr == WAIT_OBJECT_0 + 1)
            break;                                            /* shutdown */
        if (wr != WAIT_OBJECT_0) {
            DWORD we = GetLastError();
            rae_logf("wasapi: render wait failed (wr=%lu, error %lu) — render thread exiting",
                     wr, we);
            atomic_store_explicit(&w->device_error,
                                  we ? (uint32_t)HRESULT_FROM_WIN32(we)
                                     : 0x80004005u /* E_FAIL */,
                                  memory_order_relaxed);
            break;
        }

        UINT32  pad = 0;
        HRESULT hr  = IAudioClient_GetCurrentPadding(w->client, &pad);
        if (FAILED(hr)) {
            if (!dev_failed) {
                rae_logf("wasapi: GetCurrentPadding failed (hr=0x%08lX)", (unsigned long)hr);
                dev_failed = true;
                atomic_store_explicit(&w->device_error, (uint32_t)hr,
                                      memory_order_relaxed);
            }
            continue;
        }

        uint64_t submitted = atomic_load(&w->frames_rendered);
        atomic_store(&w->played_position, submitted >= pad ? submitted - pad : 0);
        UINT32 frames = w->buffer_frames - pad;
        if (frames == 0)
            continue;

        BYTE *p = NULL;
        hr = IAudioRenderClient_GetBuffer(w->render, frames, &p);
        if (FAILED(hr)) {
            if (!dev_failed) {
                rae_logf("wasapi: GetBuffer(%u) failed (hr=0x%08lX)", frames, (unsigned long)hr);
                dev_failed = true;
                atomic_store_explicit(&w->device_error, (uint32_t)hr,
                                      memory_order_relaxed);
            }
            continue;
        }

        size_t want   = (size_t)frames * (size_t)w->channels;   /* floats */
        size_t pulled = rae_ring_pull(w->ring, (float *)p, want);
        if (pulled < want) {
            memset((float *)p + pulled, 0, (want - pulled) * sizeof(float));
            /* one underrun EVENT per short pull, counted only while started */
            if (atomic_load_explicit(&w->started, memory_order_relaxed))
                atomic_fetch_add_explicit(&w->underruns, 1, memory_order_relaxed);
        }

        hr = IAudioRenderClient_ReleaseBuffer(w->render, frames, 0);
        if (FAILED(hr)) {
            if (!dev_failed) {
                rae_logf("wasapi: ReleaseBuffer(%u) failed (hr=0x%08lX)", frames,
                         (unsigned long)hr);
                dev_failed = true;
                atomic_store_explicit(&w->device_error, (uint32_t)hr,
                                      memory_order_relaxed);
            }
            continue;
        }
        uint64_t start = atomic_fetch_add(&w->frames_rendered, frames);
        if (pulled) {
            atomic_store(&w->last_input_end, start + pulled / w->channels);
            atomic_fetch_add(&w->input_frames, pulled / w->channels);
        }
    }

    if (mmcss != NULL)
        AvRevertMmThreadCharacteristics(mmcss);
    if (SUCCEEDED(co))
        CoUninitialize();
    return 0;
}

/* Release/close everything except the thread (join is close()'s job; open's
 * failure path never created the thread).  Stop result is deliberately
 * ignored: S_FALSE when already stopped, NOT_INITIALIZED on the open-failure
 * path — neither is news.  NULL-safe throughout. */
static void rae_wasapi_destroy(rae_wasapi *w)
{
    if (w == NULL)
        return;
    if (w->client != NULL)
        (void)IAudioClient_Stop(w->client);
    if (w->render != NULL)
        IAudioRenderClient_Release(w->render);
    if (w->client != NULL)
        IAudioClient_Release(w->client);
    if (w->audio_event != NULL)
        CloseHandle(w->audio_event);
    if (w->shutdown_event != NULL)
        CloseHandle(w->shutdown_event);
    free(w);
}

rae_err rae_wasapi_open(rae_wasapi **out, int sample_rate, int channels,
                        rae_ring *ring)
{
    if (out != NULL)
        *out = NULL;
    if (out == NULL || ring == NULL ||
        sample_rate <= 0 || channels < 1 || channels > 8) {
        rae_logf("wasapi: open: invalid arguments (out=%p ring=%p sr=%d ch=%d)",
                 (void *)out, (void *)ring, sample_rate, channels);
        return RAE_E_INVALID;
    }

    rae_wasapi *w = calloc(1, sizeof *w);
    if (w == NULL) {
        rae_logf("wasapi: open: out of memory (%zu bytes)", sizeof *w);
        return RAE_E_OOM;
    }
    w->sample_rate = sample_rate;
    w->channels    = channels;
    w->ring        = ring;

    IMMDeviceEnumerator *enumr = NULL;
    IMMDevice           *dev   = NULL;

    HRESULT hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                                  &IID_IMMDeviceEnumerator, (void **)&enumr);
    if (FAILED(hr)) {
        rae_logf("wasapi: CoCreateInstance(MMDeviceEnumerator) failed (hr=0x%08lX)",
                 (unsigned long)hr);
        goto fail;
    }

    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumr, eRender, eMultimedia, &dev);
    if (FAILED(hr)) {
        rae_logf("wasapi: GetDefaultAudioEndpoint(eRender) failed (hr=0x%08lX) — no audio device?",
                 (unsigned long)hr);
        goto fail;
    }

    hr = IMMDevice_Activate(dev, &IID_IAudioClient, CLSCTX_ALL, NULL,
                            (void **)&w->client);
    if (FAILED(hr)) {
        rae_logf("wasapi: IMMDevice::Activate(IAudioClient) failed (hr=0x%08lX)",
                 (unsigned long)hr);
        goto fail;
    }

    WAVEFORMATEXTENSIBLE wfx;
    memset(&wfx, 0, sizeof wfx);
    wfx.Format.wFormatTag           = WAVE_FORMAT_EXTENSIBLE;
    wfx.Format.nChannels            = (WORD)channels;
    wfx.Format.nSamplesPerSec       = (DWORD)sample_rate;
    wfx.Format.wBitsPerSample       = 32;
    wfx.Format.nBlockAlign          = (WORD)(channels * 4);
    wfx.Format.nAvgBytesPerSec      = (DWORD)sample_rate * (DWORD)(channels * 4);
    wfx.Format.cbSize               = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    wfx.Samples.wValidBitsPerSample = 32;
    wfx.dwChannelMask               = (channels == 1) ? SPEAKER_FRONT_CENTER
                                    : (channels == 2) ? (SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT)
                                    : ((1u << channels) - 1);
    wfx.SubFormat                   = rae_subtype_ieee_float;

    hr = IAudioClient_Initialize(w->client, AUDCLNT_SHAREMODE_SHARED,
                                 AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                                 AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                 AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                 RAE_WASAPI_BUFFER_HNS, 0, &wfx.Format, NULL);
    if (FAILED(hr)) {
        rae_logf("wasapi: IAudioClient::Initialize(%d Hz x %d ch float32) failed (hr=0x%08lX)",
                 sample_rate, channels, (unsigned long)hr);
        goto fail;
    }

    w->audio_event    = CreateEventW(NULL, FALSE, FALSE, NULL);
    w->shutdown_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (w->audio_event == NULL || w->shutdown_event == NULL) {
        rae_logf("wasapi: CreateEventW failed (error %lu)", GetLastError());
        goto fail;
    }

    hr = IAudioClient_SetEventHandle(w->client, w->audio_event);
    if (FAILED(hr)) {
        rae_logf("wasapi: SetEventHandle failed (hr=0x%08lX)", (unsigned long)hr);
        goto fail;
    }

    hr = IAudioClient_GetBufferSize(w->client, &w->buffer_frames);
    if (FAILED(hr) || w->buffer_frames == 0) {
        rae_logf("wasapi: GetBufferSize failed (hr=0x%08lX, frames=%u)",
                 (unsigned long)hr, w->buffer_frames);
        goto fail;
    }

    hr = IAudioClient_GetService(w->client, &IID_IAudioRenderClient,
                                 (void **)&w->render);
    if (FAILED(hr)) {
        rae_logf("wasapi: GetService(IAudioRenderClient) failed (hr=0x%08lX)",
                 (unsigned long)hr);
        goto fail;
    }

    /* Thread starts parked: the audio event cannot fire before Start. */
    uintptr_t th = _beginthreadex(NULL, 0, rae_wasapi_render_thread, w, 0, NULL);
    if (th == 0) {
        rae_logf("wasapi: _beginthreadex(render) failed (errno %d)", errno);
        goto fail;
    }
    w->thread = (HANDLE)th;

    IMMDevice_Release(dev);
    IMMDeviceEnumerator_Release(enumr);

    rae_logf("wasapi: open ok — %d Hz x %d ch float32, device buffer %u frames (~%u ms)",
             sample_rate, channels, w->buffer_frames,
             (unsigned)(((uint64_t)w->buffer_frames * 1000u) / (unsigned)sample_rate));
    *out = w;
    return RAE_OK;

fail:
    if (dev != NULL)
        IMMDevice_Release(dev);
    if (enumr != NULL)
        IMMDeviceEnumerator_Release(enumr);
    rae_wasapi_destroy(w);
    return RAE_E_AUDIO;
}

rae_err rae_wasapi_start(rae_wasapi *w)
{
    if (w == NULL) {
        rae_logf("wasapi: start: NULL instance");
        return RAE_E_INVALID;
    }

    /* Pre-roll from the TUNER thread — legal: client not started, no event
     * contention with the (parked) render thread.  Padding is 0 on a fresh
     * client; queried anyway so start-after-stop stays correct. */
    UINT32  pad = 0;
    HRESULT hr  = IAudioClient_GetCurrentPadding(w->client, &pad);
    if (FAILED(hr)) {
        rae_logf("wasapi: start: GetCurrentPadding failed (hr=0x%08lX)", (unsigned long)hr);
        return RAE_E_AUDIO;
    }
    UINT32 frames = w->buffer_frames - pad;
    if (frames > 0) {
        BYTE *p = NULL;
        hr = IAudioRenderClient_GetBuffer(w->render, frames, &p);
        if (FAILED(hr)) {
            rae_logf("wasapi: start: GetBuffer(%u) failed (hr=0x%08lX)", frames,
                     (unsigned long)hr);
            return RAE_E_AUDIO;
        }
        size_t want   = (size_t)frames * (size_t)w->channels;
        size_t pulled = rae_ring_pull(w->ring, (float *)p, want);
        if (pulled < want)
            memset((float *)p + pulled, 0, (want - pulled) * sizeof(float));
        hr = IAudioRenderClient_ReleaseBuffer(w->render, frames, 0);
        if (FAILED(hr)) {
            rae_logf("wasapi: start: ReleaseBuffer(%u) failed (hr=0x%08lX)", frames,
                     (unsigned long)hr);
            return RAE_E_AUDIO;
        }
        uint64_t start = atomic_fetch_add(&w->frames_rendered, frames);
        if (pulled) {
            atomic_store(&w->last_input_end, start + pulled / w->channels);
            atomic_fetch_add(&w->input_frames, pulled / w->channels);
        }
    }

    hr = IAudioClient_Start(w->client);
    if (FAILED(hr)) {
        rae_logf("wasapi: IAudioClient::Start failed (hr=0x%08lX)", (unsigned long)hr);
        return RAE_E_AUDIO;
    }
    atomic_store_explicit(&w->started, true, memory_order_release);
    return RAE_OK;
}

void rae_wasapi_stop(rae_wasapi *w)
{
    if (w == NULL)
        return;
    atomic_store_explicit(&w->started, false, memory_order_release);
    HRESULT hr = IAudioClient_Stop(w->client);
    if (FAILED(hr))
        rae_logf("wasapi: IAudioClient::Stop failed (hr=0x%08lX)", (unsigned long)hr);
    /* render thread stays parked on the now-silent event */
}

bool rae_wasapi_close(rae_wasapi *w)
{
    if (w == NULL)
        return true;
    atomic_store_explicit(&w->started, false, memory_order_release);

    if (w->thread != NULL) {
        SetEvent(w->shutdown_event);
        /* This runs on the dedicated MTA owner. Tcl can close immediately:
         * the owner retains the endpoint and ring until render exits. */
        if (WaitForSingleObject(w->thread, INFINITE) != WAIT_OBJECT_0) return false;
        CloseHandle(w->thread);
        w->thread = NULL;
    }

    rae_wasapi_destroy(w);   /* Stop, release interfaces, close events, free */
    return true;
}

bool rae_wasapi_finished(const rae_wasapi *w, uint64_t frames)
{
    return atomic_load(&w->input_frames) >= frames &&
           atomic_load(&w->played_position) >= atomic_load(&w->last_input_end);
}

uint64_t rae_wasapi_underruns(const rae_wasapi *w)
{
    if (w == NULL)
        return 0;
    return atomic_load_explicit((_Atomic uint64_t *)&w->underruns,
                                memory_order_relaxed);
}

uint64_t rae_wasapi_frames_rendered(const rae_wasapi *w)
{
    if (w == NULL)
        return 0;
    return atomic_load_explicit((_Atomic uint64_t *)&w->frames_rendered,
                                memory_order_relaxed);
}

uint32_t rae_wasapi_device_error(const rae_wasapi *w)
{
    if (w == NULL)
        return 0;
    return atomic_load_explicit((_Atomic uint32_t *)&w->device_error,
                                memory_order_relaxed);
}
