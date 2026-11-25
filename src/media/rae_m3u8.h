/* HLS master and media playlist parser. Adapted from Rae (MIT), see licenses/rae.txt. */
#ifndef RAE_M3U8_H
#define RAE_M3U8_H

#include "rae_common.h"

typedef enum rae_m3u8_kind { RAE_M3U8_MASTER, RAE_M3U8_MEDIA } rae_m3u8_kind;

typedef struct rae_m3u8_variant {
    uint32_t bandwidth;             /* BANDWIDTH attr, bits/sec; 0 = absent  */
    char     codecs[64];            /* CODECS attr sans quotes; "" = absent  */
    char     uri[RAE_URL_MAX];      /* verbatim from the playlist            */
} rae_m3u8_variant;

typedef struct rae_m3u8_segment {
    char   uri[RAE_URL_MAX];        /* verbatim                              */
    double duration;                /* EXTINF seconds                        */
    bool   discontinuity;           /* #EXT-X-DISCONTINUITY preceded this    */
} rae_m3u8_segment;

typedef struct rae_m3u8 {
    rae_m3u8_kind kind;

    /* MASTER (else count 0 / ptr NULL) */
    rae_m3u8_variant *variants;     /* malloc'd array, freed by rae_m3u8_free */
    size_t            variant_count;

    /* MEDIA (else zeroed) */
    rae_m3u8_segment *segments;     /* malloc'd array, freed by rae_m3u8_free */
    size_t            segment_count;
    double            target_duration;  /* seconds, clamped to [1.0, 60.0]   */
    uint64_t          media_sequence;   /* sequence number of segments[0]    */
    bool              endlist;
    bool              has_map;          /* #EXT-X-MAP seen (fMP4 ⇒ M2)       */
    char              key_method[32];   /* "" = no EXT-X-KEY tag             */
} rae_m3u8;

/* Parse text[0..len).  On RAE_OK, *out is fully populated (callee zeroes it
 * first); caller MUST rae_m3u8_free(out) exactly once.  On any error *out is
 * zeroed and needs no free.  Errors: RAE_E_PLAYLIST (not a/that playlist),
 * RAE_E_FORMAT (oversized URI), RAE_E_OOM, RAE_E_INVALID.                   */
rae_err rae_m3u8_parse(const char *text, size_t len, rae_m3u8 *out);

/* Frees the variant/segment arrays; idempotent; NULL-safe. */
void rae_m3u8_free(rae_m3u8 *p);

/* ── URL join (RFC 3986 resolution, the subset live HLS needs) ─────────────
 * base MUST be absolute (scheme://host[:port]/path…).  Rules, in order:
 *   rel == ""                → copy base;
 *   rel has a scheme (":..." before any '/' '?' '#') → copy rel;
 *   rel starts "//"          → base's scheme + ":" + rel;
 *   rel starts "/"           → base's scheme://authority + rel;
 *   otherwise                → base truncated after the last '/' of its PATH
 *                              (query/fragment of base dropped; a path with
 *                              no '/' becomes "/") + rel.
 * Percent-escapes are NEVER touched (the BBC "%3d" rule); "." and ".."
 * segments are NOT normalized in M0 (document if a real playlist needs it).
 * out must hold RAE_URL_MAX bytes; overflow ⇒ RAE_E_FORMAT; base not
 * absolute ⇒ RAE_E_INVALID.                                                 */
rae_err rae_url_join(const char *base, const char *rel, char out[RAE_URL_MAX]);

#endif /* RAE_M3U8_H */
