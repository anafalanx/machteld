# Audio fixture provenance

The four files contain one half-second of original 48 kHz stereo audio. The
tone has a frequency of 440 Hz. The silence fixture lets an unattended test
send decoded HLS audio through the real Windows endpoint.

`generate.c` uses LAME 3.100 for MP3 and FDK AAC 2.0.3 for ADTS AAC-LC
and HE-AAC. These encoders are test-author tools. The runtime decodes MP3
with minimp3 and AAC with Windows Media Foundation.

The fixtures in this directory were made with these MSYS2 UCRT64 package
archives and SHA-256 hashes.

| Archive | SHA-256 |
| --- | --- |
| `mingw-w64-ucrt-x86_64-lame-3.100-3-any.pkg.tar.zst` | `6bc4bf7d2f39a941a695b228818a8c846a53c43c20117e0707e08977b0dd0da9` |
| `mingw-w64-ucrt-x86_64-fdk-aac-2.0.3-1-any.pkg.tar.zst` | `e08846148086d898d4affa0303a3fcccd0dc97017487017e4cb18dab95a10150` |

With the encoder development files installed, run from this directory.

```sh
gcc -std=c23 -O2 generate.c -lmp3lame -lfdk-aac -o generate
./generate
```

The HLS test creates its MPEG-TS packets in memory from these original AAC
frames. Runtime portions adapted from Rae carry its MIT notice. The vendored
minimp3 header carries its CC0 dedication and has SHA-256
`5fb296a790734772b65a5514438cc06d14f24e539c13475ff2a7f737681c82c0`.

The release gate renders silence for its audio endpoint tests. For the
attended listening check, run `machteld.exe test/audio_test.tcl --audible`
and record whether the half-second 440 Hz tone was heard.
