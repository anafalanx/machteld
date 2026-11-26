/* The WASAPI owner initializes COM on a dedicated MTA thread, even when Tk
 * already uses an STA. Tcl owns the producer side of a bounded PCM ring. */
#include "audio_internal.h"
#include "media/rae_wasapi.h"
#include <objbase.h>
#include <process.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>

typedef enum { OPENING, READY, PLAYING, DONE, STOPPED, DEVICE_FAILED } OutputState;
typedef struct {
    Tcl_Command command;
    LONG refs;
    HANDLE stop, changed;
    rae_ring ring;
    int rate, channels;
    _Atomic int state;
    _Atomic bool finish;
    _Atomic uint64_t accepted;
    char diagnostic[512];
} Output;

static void destroy_output(Output *o) {
    if (o->stop) CloseHandle(o->stop);
    if (o->changed) CloseHandle(o->changed);
    rae_ring_free(&o->ring);
    free(o);
}

static void release_output(Output *o) {
    if (InterlockedDecrement(&o->refs) == 0) destroy_output(o);
}

static void output_delete(void *data) {
    Output *o = data;
    SetEvent(o->stop);
    release_output(o);
}

static unsigned __stdcall own_device(void *data) {
    Output *o = data;
    rae_wasapi *device = NULL;
    OutputState terminal = STOPPED;
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    rae_err rc = FAILED(hr) ? RAE_E_AUDIO : rae_wasapi_open(&device, o->rate, o->channels, &o->ring);
    if (rc != RAE_OK) {
        snprintf(o->diagnostic, sizeof o->diagnostic, "%s", media_last_error());
        terminal = DEVICE_FAILED;
    } else {
        atomic_store(&o->state, READY);
        HANDLE signals[2] = {o->stop, o->changed};
        bool started = false;
        for (;;) {
            DWORD wait = WaitForMultipleObjects(2, signals, FALSE, started ? 10 : INFINITE);
            if (wait == WAIT_OBJECT_0) break;
            if (wait == WAIT_FAILED) {
                snprintf(o->diagnostic, sizeof o->diagnostic, "audio wait failed: win32 %lu", GetLastError());
                terminal = DEVICE_FAILED;
                break;
            }
            uint64_t accepted = atomic_load(&o->accepted);
            if (!started && accepted) {
                if (rae_wasapi_start(device) != RAE_OK) {
                    snprintf(o->diagnostic, sizeof o->diagnostic, "%s", media_last_error());
                    terminal = DEVICE_FAILED;
                    break;
                }
                started = true;
                atomic_store(&o->state, PLAYING);
            }
            uint32_t error = rae_wasapi_device_error(device);
            if (error) {
                snprintf(o->diagnostic, sizeof o->diagnostic, "Windows audio device failed (HRESULT 0x%08lx)", (unsigned long)error);
                terminal = DEVICE_FAILED;
                break;
            }
            if (atomic_load(&o->finish) && rae_wasapi_finished(device, atomic_load(&o->accepted))) {
                terminal = DONE;
                break;
            }
        }
        if (!rae_wasapi_close(device)) {
            snprintf(o->diagnostic, sizeof o->diagnostic, "could not join the Windows audio render thread");
            atomic_store(&o->state, DEVICE_FAILED);
            /* Windows still owns a ring pointer. Keep the worker reference. */
            if (SUCCEEDED(hr)) CoUninitialize();
            return 1;
        }
    }
    if (SUCCEEDED(hr)) CoUninitialize();
    /* Terminal state means the endpoint has already been released. */
    atomic_store(&o->state, terminal);
    release_output(o);
    return 0;
}

static int output_command(void *data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Output *o = data;
    static const char *const words[] = {"write", "status", "finish", "stop", "close", NULL};
    enum { WRITE, STATUS, FINISH, STOP, CLOSE };
    int op;
    if (objc < 2) { Tcl_WrongNumArgs(interp, 1, objv, "write|status|finish|stop|close ?f32le?"); return TCL_ERROR; }
    if (Tcl_GetIndexFromObj(interp, objv[1], words, "operation", TCL_EXACT, &op) != TCL_OK) return TCL_ERROR;
    if (objc != (op == WRITE ? 3 : 2)) { Tcl_WrongNumArgs(interp, 2, objv, op == WRITE ? "f32le" : ""); return TCL_ERROR; }
    if (op == CLOSE) { Tcl_DeleteCommandFromToken(interp, o->command); return TCL_OK; }
    if (op == STOP) { SetEvent(o->stop); return TCL_OK; }
    OutputState state = atomic_load(&o->state);
    if (op == STATUS) {
        static const char *const names[] = {"opening", "ready", "playing", "done", "stopped", "error"};
        Tcl_Obj *result = Tcl_NewDictObj();
        audio_put(result, "state", Tcl_NewStringObj(names[state], -1));
        audio_put(result, "queuedFrames", Tcl_NewWideIntObj((Tcl_WideInt)(rae_ring_level(&o->ring) / o->channels)));
        audio_put(result, "acceptedFrames", Tcl_NewWideIntObj((Tcl_WideInt)atomic_load(&o->accepted)));
        if (state == DEVICE_FAILED) audio_put(result, "message", Tcl_NewStringObj(o->diagnostic, -1));
        Tcl_SetObjResult(interp, result);
        return TCL_OK;
    }
    if (state == DEVICE_FAILED) return audio_error(interp, "device", o->diagnostic);
    if (op == FINISH) {
        atomic_store(&o->finish, true);
        SetEvent(o->changed);
        return TCL_OK;
    }
    if (atomic_load(&o->finish) || WaitForSingleObject(o->stop, 0) == WAIT_OBJECT_0 || state == DONE || state == STOPPED)
        return audio_error(interp, "state", "the PCM output has stopped accepting samples");
    Tcl_Size length;
    const unsigned char *bytes = Tcl_GetByteArrayFromObj(objv[2], &length);
    unsigned frameBytes = (unsigned)o->channels * sizeof(float);
    if (!bytes || (length % frameBytes)) return audio_error(interp, "format", "float32 PCM must contain whole sample frames");
    size_t capacity = o->ring.cap - rae_ring_level(&o->ring);
    size_t frames = (size_t)length / frameBytes;
    if (frames > capacity / o->channels) frames = capacity / o->channels;
    /* The ring copies bytes with memcpy; materialized Tcl byte arrays need
     * no alignment or lifetime beyond this Tcl call. */
    size_t n = rae_ring_push(&o->ring, (const float *)(const void *)bytes, frames * o->channels);
    atomic_fetch_add(&o->accepted, n / o->channels);
    if (n) SetEvent(o->changed);
    Tcl_SetObjResult(interp, Tcl_NewWideIntObj((Tcl_WideInt)(n * sizeof(float))));
    return TCL_OK;
}

int audio_output(Tcl_Interp *interp, Tcl_Obj *rateObj, Tcl_Obj *channelsObj) {
    int rate, channels;
    if (Tcl_GetIntFromObj(interp, rateObj, &rate) != TCL_OK ||
        Tcl_GetIntFromObj(interp, channelsObj, &channels) != TCL_OK) return TCL_ERROR;
    if (rate < 8000 || rate > 192000 || channels < 1 || channels > 8)
        return audio_error(interp, "format", "expected 8000 to 192000 Hz and one to eight channels");
    Output *o = calloc(1, sizeof *o);
    if (!o) return audio_error(interp, "oserror", "out of memory creating PCM output");
    o->rate = rate;
    o->channels = channels;
    if (rae_ring_init(&o->ring, (size_t)rate * (size_t)channels / 2) != RAE_OK ||
        !(o->stop = CreateEventW(NULL, TRUE, FALSE, NULL)) ||
        !(o->changed = CreateEventW(NULL, FALSE, FALSE, NULL))) {
        destroy_output(o);
        return audio_error(interp, "oserror", "cannot allocate the PCM queue");
    }
    /* The Tcl command and the device thread each own a reference once the
     * thread starts. Until then only this function can access the output. */
    o->refs = 2;
    uintptr_t owner = _beginthreadex(NULL, 0, own_device, o, 0, NULL);
    if (!owner) {
        destroy_output(o);
        return audio_error(interp, "oserror", "cannot start the audio device owner");
    }
    CloseHandle((HANDLE)owner);
    return audio_handle(interp, "audioOutput", output_command, o, output_delete, &o->command);
}
