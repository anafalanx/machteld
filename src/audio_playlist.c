#include "audio_internal.h"
#include "media/rae_m3u8.h"
#include "media/rae_ts.h"
#include <string.h>

#define PLAYLIST_BYTES (1024 * 1024)
#define SEGMENT_BYTES (16 * 1024 * 1024)

static int resolved(Tcl_Interp *interp, Tcl_Obj *item, const char *base, const char *uri) {
    char absolute[RAE_URL_MAX];
    if (rae_url_join(base, uri, absolute) != RAE_OK ||
        (strncmp(absolute, "http://", 7) && strncmp(absolute, "https://", 8))) {
        return audio_error(interp, "format", "playlist URI must resolve to an HTTP or HTTPS URL");
    }
    audio_put(item, "url", Tcl_NewStringObj(absolute, -1));
    return TCL_OK;
}

int audio_playlist(Tcl_Interp *interp, Tcl_Obj *baseObj, Tcl_Obj *input) {
    Tcl_Size count, baseLength;
    const char *base = Tcl_GetStringFromObj(baseObj, &baseLength);
    if (baseLength >= RAE_URL_MAX || memchr(base, 0, (size_t)baseLength) ||
            (strncmp(base, "http://", 7) && strncmp(base, "https://", 8))) {
        return audio_error(interp, "format", "expected an HTTP or HTTPS playlist URL under 2048 bytes");
    }
    Tcl_DString scratch;
    const unsigned char *bytes = Machteld_ValueBytes(input, &count, &scratch);
    if (count > PLAYLIST_BYTES) {
        Tcl_DStringFree(&scratch);
        return audio_error(interp, "limit", "playlist exceeds one MiB");
    }
    if (memchr(bytes, 0, (size_t)count)) {
        Tcl_DStringFree(&scratch);
        return audio_error(interp, "format", "playlist contains a NUL byte");
    }
    rae_m3u8 playlist;
    rae_err rc = rae_m3u8_parse((const char *)bytes, (size_t)count, &playlist);
    Tcl_DStringFree(&scratch);
    if (rc != RAE_OK) return audio_runtime_error(interp, rc);
    if (playlist.has_map || (playlist.key_method[0] && strcmp(playlist.key_method, "NONE"))) {
        rae_m3u8_free(&playlist);
        return audio_error(interp, "unsupported", "expected unencrypted MPEG-TS media");
    }
    bool master = playlist.kind == RAE_M3U8_MASTER;
    if (playlist.media_sequence > (uint64_t)INT64_MAX - playlist.segment_count) {
        rae_m3u8_free(&playlist);
        return audio_error(interp, "format", "HLS media sequence number exceeds the supported range");
    }
    Tcl_Obj *result = Tcl_NewDictObj(), *items = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(result);
    audio_put(result, "kind", Tcl_NewStringObj(master ? "master" : "media", -1));
    audio_put(result, master ? "variants" : "segments", items);
    if (!master) {
        audio_put(result, "target", Tcl_NewDoubleObj(playlist.target_duration));
        audio_put(result, "ended", Tcl_NewBooleanObj(playlist.endlist));
    }
    int status = TCL_OK;
    size_t n = master ? playlist.variant_count : playlist.segment_count;
    for (size_t i = 0; i < n; i++) {
        Tcl_Obj *item = Tcl_NewDictObj();
        Tcl_ListObjAppendElement(NULL, items, item);
        if (master) {
            rae_m3u8_variant *v = &playlist.variants[i];
            audio_put(item, "bandwidth", Tcl_NewWideIntObj(v->bandwidth));
            audio_put(item, "codecs", Tcl_NewStringObj(v->codecs, -1));
            status = resolved(interp, item, base, v->uri);
        } else {
            rae_m3u8_segment *s = &playlist.segments[i];
            audio_put(item, "sequence", Tcl_NewWideIntObj((Tcl_WideInt)(playlist.media_sequence + i)));
            audio_put(item, "duration", Tcl_NewDoubleObj(s->duration));
            audio_put(item, "discontinuity", Tcl_NewBooleanObj(s->discontinuity));
            status = resolved(interp, item, base, s->uri);
        }
        if (status != TCL_OK) break;
    }
    rae_m3u8_free(&playlist);
    if (status == TCL_OK) Tcl_SetObjResult(interp, result);
    Tcl_DecrRefCount(result);
    return status;
}

static void payload(void *data, const uint8_t *bytes, size_t count) {
    Tcl_DStringAppend((Tcl_DString *)data, (const char *)bytes, (Tcl_Size)count);
}

int audio_demux(Tcl_Interp *interp, Tcl_Obj *input) {
    Tcl_Size n;
    const unsigned char *bytes = Tcl_GetByteArrayFromObj(input, &n);
    if (!bytes || n < 188 || n % 188) return audio_error(interp, "format", "expected whole 188-byte transport packets");
    if (n > SEGMENT_BYTES) return audio_error(interp, "limit", "transport segment exceeds 16 MiB");
    Tcl_DString body;
    Tcl_DStringInit(&body);
    rae_ts *ts = NULL;
    rae_err rc = rae_ts_create(&ts, payload, &body);
    if (rc == RAE_OK) rc = rae_ts_feed(ts, bytes, (size_t)n);
    int status = TCL_ERROR;
    if (rc == RAE_OK) {
        rae_ts_flush(ts);
        const rae_ts_stats *stats = rae_ts_get_stats(ts);
        if (!stats->pat_seen || !stats->pmt_seen || !stats->payload_bytes ||
                stats->error_packets || stats->cc_discontinuities) {
            audio_error(interp, "format", "transport segment is missing valid ordered audio packets");
        } else {
            Tcl_Obj *result = Tcl_NewDictObj();
            audio_put(result, "codec", Tcl_NewStringObj(stats->audio_stream_type == 0x0f ? "aac" : "mp3", -1));
            audio_put(result, "data", Tcl_NewByteArrayObj((const unsigned char *)Tcl_DStringValue(&body), Tcl_DStringLength(&body)));
            Tcl_SetObjResult(interp, result);
            status = TCL_OK;
        }
    } else {
        audio_runtime_error(interp, rc);
    }
    if (ts) rae_ts_destroy(ts);
    Tcl_DStringFree(&body);
    return status;
}
