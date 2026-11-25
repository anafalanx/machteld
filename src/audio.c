/* Tcl handles for streaming compressed audio. Consumers pull one PCM frame
 * at a time and can feed it directly to the bounded Windows output handle. */
#include "audio_internal.h"
#include "media/foundation.h"
#include "media/rae_aac.h"
#include "media/rae_adts.h"
#include "media/rae_mp3.h"
#include <objbase.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int audio_error(Tcl_Interp *interp, const char *code, const char *message) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(message, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "AUDIO", code, NULL);
    return TCL_ERROR;
}

int audio_runtime_error(Tcl_Interp *interp, rae_err rc) {
    const char *code = rc == RAE_E_OOM ? "oserror" :
        rc == RAE_E_AUDIO ? "device" : rc == RAE_E_UNSUPPORTED ? "unsupported" : "format";
    const char *message = media_last_error();
    return audio_error(interp, code, *message ? message : "the media operation failed");
}

void audio_put(Tcl_Obj *d, const char *key, Tcl_Obj *value) {
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj(key, -1), value);
}

int audio_handle(Tcl_Interp *interp, const char *type, Tcl_ObjCmdProc *proc,
                 void *data, Tcl_CmdDeleteProc *destroy, Tcl_Command *command) {
    static LONG64 serial;
    char name[80];
    do {
        snprintf(name, sizeof name, "::machteld::%s%lld", type, (long long)InterlockedIncrement64(&serial));
    } while (Tcl_FindCommand(interp, name, NULL, TCL_GLOBAL_ONLY));
    *command = Tcl_CreateObjCommand(interp, name, proc, data, destroy);
    if (!*command) { destroy(data); return TCL_ERROR; }
    Tcl_SetObjResult(interp, Tcl_NewStringObj(name, -1));
    return TCL_OK;
}

typedef struct {
    Tcl_Command command;
    rae_mp3 *mp3;
    rae_adts *adts;
    rae_aac *aac;
    bool com, foundation, finishing, draining, decoded, failed;
} Decoder;

static void decoder_delete(void *data) {
    Decoder *d = data;
    if (d->aac) rae_aac_destroy(d->aac);
    if (d->adts) rae_adts_destroy(d->adts);
    if (d->mp3) rae_mp3_destroy(d->mp3);
    if (d->foundation) media_foundation_stop();
    if (d->com) CoUninitialize();
    free(d);
}

static size_t pending(const Decoder *d) {
    return d->mp3 ? rae_mp3_pending(d->mp3) : rae_adts_pending(d->adts);
}

static rae_err pull(Decoder *d, const float **pcm, size_t *n, int *rate, int *channels) {
    if (d->mp3) return rae_mp3_pull(d->mp3, pcm, n, rate, channels);
    for (;;) {
        if (d->aac) {
            rae_err rc = rae_aac_pull(d->aac, pcm, n, rate, channels);
            if (rc != RAE_OK || *n) return rc;
        }
        rae_adts_frame frame;
        if (rae_adts_next(d->adts, &frame)) {
            if (!d->aac) {
                rae_err rc = rae_aac_create(&d->aac, frame.sample_rate, frame.channels, frame.profile);
                if (rc != RAE_OK) return rc;
            }
            rae_err rc = rae_aac_feed(d->aac, frame.data, frame.len);
            if (rc != RAE_OK) return rc;
        } else if (d->finishing && d->aac && !d->draining) {
            d->draining = true;
            rae_err rc = rae_aac_drain(d->aac);
            if (rc != RAE_OK) return rc;
        } else {
            return RAE_OK;
        }
    }
}

static int decoder_command(void *data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Decoder *d = data;
    enum { FEED, READ, FINISH, CLOSE };
    static const char *const words[] = {"feed", "read", "finish", "close", NULL};
    int op;
    if (objc < 2) { Tcl_WrongNumArgs(interp, 1, objv, "feed|read|finish|close ?bytes?"); return TCL_ERROR; }
    if (Tcl_GetIndexFromObj(interp, objv[1], words, "operation", TCL_EXACT, &op) != TCL_OK) return TCL_ERROR;
    if (objc != (op == FEED ? 3 : 2)) { Tcl_WrongNumArgs(interp, 2, objv, op == FEED ? "bytes" : ""); return TCL_ERROR; }
    if (op == CLOSE) { Tcl_DeleteCommandFromToken(interp, d->command); return TCL_OK; }
    if (d->failed) return audio_error(interp, "format", "this decoder failed; close it before starting another stream");
    if (op == FINISH) {
        d->finishing = true;
        if (d->adts) rae_adts_finish(d->adts);
        return TCL_OK;
    }
    if (op == FEED) {
        if (d->finishing) return audio_error(interp, "state", "the decoder has finished accepting input");
        Tcl_Size bytes;
        Tcl_DString scratch;
        const unsigned char *input = Machteld_ValueBytes(objv[2], &bytes, &scratch);
        rae_err rc = RAE_OK;
        bool tooMany = bytes > (Tcl_Size)(RAE_MP3_BUF_MAX - pending(d));
        if (!tooMany && bytes) rc = d->mp3 ? rae_mp3_feed(d->mp3, input, (size_t)bytes) :
                                              rae_adts_feed(d->adts, input, (size_t)bytes);
        Tcl_DStringFree(&scratch);
        if (tooMany) return audio_error(interp, "limit", "read PCM before feeding more than 256 KiB of compressed input");
        if (rc != RAE_OK) { d->failed = true; return audio_runtime_error(interp, rc); }
        return TCL_OK;
    }
    const float *pcm = NULL;
    size_t count = 0;
    int rate = 0, channels = 0;
    rae_err rc = pull(d, &pcm, &count, &rate, &channels);
    if (rc != RAE_OK) { d->failed = true; return audio_runtime_error(interp, rc); }
    if (!count && d->finishing && (!d->decoded || pending(d))) {
        d->failed = true;
        return audio_error(interp, "format", "the compressed stream is empty, malformed or ends in a partial frame");
    }
    Tcl_Obj *result = Tcl_NewDictObj();
    if (count) {
        d->decoded = true;
        audio_put(result, "state", Tcl_NewStringObj("data", -1));
        audio_put(result, "format", Tcl_NewStringObj("f32le", -1));
        audio_put(result, "rate", Tcl_NewIntObj(rate));
        audio_put(result, "channels", Tcl_NewIntObj(channels));
        audio_put(result, "pcm", Tcl_NewByteArrayObj((const unsigned char *)pcm, (Tcl_Size)(count * sizeof(float))));
    } else {
        audio_put(result, "state", Tcl_NewStringObj(d->finishing ? "eof" : "more", -1));
    }
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
}

static int new_decoder(Tcl_Interp *interp, Tcl_Obj *format) {
    static const char *const formats[] = {"mp3", "aac", NULL};
    int codec;
    if (Tcl_GetIndexFromObj(interp, format, formats, "codec", TCL_EXACT, &codec) != TCL_OK) return TCL_ERROR;
    Decoder *d = calloc(1, sizeof *d);
    if (!d) return audio_error(interp, "oserror", "out of memory creating decoder");
    rae_err rc;
    if (codec == 0) {
        rc = rae_mp3_create(&d->mp3);
    } else {
        HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
        d->com = SUCCEEDED(hr);
        if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
            decoder_delete(d);
            return audio_error(interp, "oserror", "Windows COM initialization failed");
        }
        if (FAILED(media_foundation_start())) {
            decoder_delete(d);
            return audio_error(interp, "unavailable", "Windows Media Foundation is unavailable");
        }
        d->foundation = true;
        rc = rae_adts_create(&d->adts);
    }
    if (rc != RAE_OK) { decoder_delete(d); return audio_runtime_error(interp, rc); }
    return audio_handle(interp, "audioDecoder", decoder_command, d, decoder_delete, &d->command);
}

static int AudioCmd(void *clientData, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)clientData;
    static const char *const words[] = {"decoder", "output", "playlist", "demux", NULL};
    enum { DECODER, OUTPUT, PLAYLIST, DEMUX };
    int op;
    if (objc < 2) { Tcl_WrongNumArgs(interp, 1, objv, "decoder|output|playlist|demux arguments"); return TCL_ERROR; }
    if (Tcl_GetIndexFromObj(interp, objv[1], words, "subcommand", TCL_EXACT, &op) != TCL_OK) return TCL_ERROR;
    const char *usage[] = {"mp3|aac", "sampleRate channels", "baseUrl bytes", "transportStreamBytes"};
    if (objc != ((op == OUTPUT || op == PLAYLIST) ? 4 : 3)) {
        Tcl_WrongNumArgs(interp, 2, objv, usage[op]);
        return TCL_ERROR;
    }
    switch (op) {
    case DECODER: return new_decoder(interp, objv[2]);
    case OUTPUT: return audio_output(interp, objv[2], objv[3]);
    case PLAYLIST: return audio_playlist(interp, objv[2], objv[3]);
    default: return audio_demux(interp, objv[2]);
    }
}

int Machteldaudio_Init(Tcl_Interp *interp) {
    if (!Tcl_CreateObjCommand(interp, "::machteld::audio", AudioCmd, NULL, NULL)) return TCL_ERROR;
    return Tcl_PkgProvide(interp, "machteld::audio", MACHTELD_VERSION);
}
