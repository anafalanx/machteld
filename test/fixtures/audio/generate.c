/* Regenerate our original 440 Hz, 48 kHz stereo fixtures. Only test authors
 * need the LAME 3.100 and FDK AAC 2.0.3 encoders. Neither ships in Machteld. */
#include <fdk-aac/aacenc_lib.h>
#include <lame/lame.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

enum { RATE = 48000, CHANNELS = 2, SAMPLES = 24000 };

static void require(int condition, const char *action) {
    if (!condition) { fprintf(stderr, "fixture generator: %s\n", action); exit(1); }
}

static void write_bytes(FILE *output, const unsigned char *data, int bytes) {
    require(bytes >= 0 && fwrite(data, 1, (size_t)bytes, output) == (size_t)bytes, "writing audio");
}

static void mp3(const short *pcm) {
    FILE *output = fopen("tone.mp3", "wb");
    lame_t encoder = lame_init();
    require(output && encoder, "opening MP3");
    lame_set_in_samplerate(encoder, RATE);
    lame_set_out_samplerate(encoder, RATE);
    lame_set_num_channels(encoder, CHANNELS);
    lame_set_brate(encoder, 96);
    lame_set_bWriteVbrTag(encoder, 0);
    require(lame_init_params(encoder) == 0, "initializing MP3");
    unsigned char buffer[65536];
    int n = lame_encode_buffer_interleaved(encoder, (short *)pcm, SAMPLES, buffer, sizeof buffer);
    write_bytes(output, buffer, n);
    n = lame_encode_flush(encoder, buffer, sizeof buffer);
    write_bytes(output, buffer, n);
    lame_close(encoder);
    require(fclose(output) == 0, "closing MP3");
}

static void aac(const short *pcm, const char *name, int object, int bitrate) {
    FILE *output = fopen(name, "wb");
    HANDLE_AACENCODER encoder = NULL;
    require(output && aacEncOpen(&encoder, 0, CHANNELS) == AACENC_OK, "opening AAC");
    require(aacEncoder_SetParam(encoder, AACENC_AOT, object) == AACENC_OK &&
        aacEncoder_SetParam(encoder, AACENC_SAMPLERATE, RATE) == AACENC_OK &&
        aacEncoder_SetParam(encoder, AACENC_CHANNELMODE, MODE_2) == AACENC_OK &&
        aacEncoder_SetParam(encoder, AACENC_BITRATE, bitrate) == AACENC_OK &&
        aacEncoder_SetParam(encoder, AACENC_TRANSMUX, TT_MP4_ADTS) == AACENC_OK &&
        aacEncEncode(encoder, NULL, NULL, NULL, NULL) == AACENC_OK, "configuring AAC");
    AACENC_InfoStruct info;
    require(aacEncInfo(encoder, &info) == AACENC_OK, "querying AAC");
    unsigned char outputBytes[8192];
    int at = 0;
    for (;;) {
        int samples = (int)info.frameLength * CHANNELS;
        if (samples > SAMPLES * CHANNELS - at) samples = SAMPLES * CHANNELS - at;
        int inSize = samples * (int)sizeof(short), inId = IN_AUDIO_DATA, inUnit = sizeof(short);
        void *inBytes = (void *)(pcm + at);
        AACENC_BufDesc input = {1, &inBytes, &inId, &inSize, &inUnit};
        void *outBytes = outputBytes;
        int outSize = sizeof outputBytes, outId = OUT_BITSTREAM_DATA, outUnit = 1;
        AACENC_BufDesc encoded = {1, &outBytes, &outId, &outSize, &outUnit};
        AACENC_InArgs inArgs = {0};
        inArgs.numInSamples = samples ? samples : -1;
        AACENC_OutArgs outArgs = {0};
        AACENC_ERROR result = aacEncEncode(encoder, &input, &encoded, &inArgs, &outArgs);
        if (result == AACENC_ENCODE_EOF) break;
        require(result == AACENC_OK, "encoding AAC");
        at += outArgs.numInSamples;
        write_bytes(output, outputBytes, outArgs.numOutBytes);
    }
    aacEncClose(&encoder);
    require(fclose(output) == 0, "closing AAC");
}

int main(void) {
    static short pcm[SAMPLES * CHANNELS];
    for (int i = 0; i < SAMPLES; ++i) {
        double fraction = (double)((i * 440) % RATE) / RATE;
        short value = (short)lrint(12000 * sin(6.2831853071795864769 * fraction));
        pcm[i * 2] = pcm[i * 2 + 1] = value;
    }
    mp3(pcm);
    aac(pcm, "tone-lc.aac", AOT_AAC_LC, 96000);
    aac(pcm, "tone-he.aac", AOT_SBR, 48000);
    static const short silence[SAMPLES * CHANNELS];
    aac(silence, "silence-lc.aac", AOT_AAC_LC, 96000);
    return 0;
}
