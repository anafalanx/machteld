/* HLS master and media playlist parser. Adapted from Rae (MIT), see licenses/rae.txt. */

#include "rae_common.h"
#include "rae_m3u8.h"

#include <stdlib.h>
#include <string.h>

/* ── ASCII helpers (no <ctype.h>: locale-free, no signed-char UB) ────────── */

static bool ascii_alpha(char c)
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

static bool ascii_scheme_char(char c)   /* RFC 3986 scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) */
{
    return ascii_alpha(c) || (c >= '0' && c <= '9') ||
           c == '+' || c == '-' || c == '.';
}

static bool ascii_nieq(const char *a, const char *b, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        char ca = a[i], cb = b[i];
        if (ca >= 'a' && ca <= 'z') ca = (char)(ca - 32);
        if (cb >= 'a' && cb <= 'z') cb = (char)(cb - 32);
        if (ca != cb) return false;
    }
    return true;
}

/* ── tag and attribute-list parsing ──────────────────────────────────────── */

/* If `line` is tag `tag` (exact tag-name boundary: next char ':' or end),
 * return the value pointer (past the ':', or the "" at line end); else
 * nullptr.  The boundary check is what keeps "#EXT-X-DISCONTINUITY-SEQUENCE"
 * from matching "#EXT-X-DISCONTINUITY" and "#EXT-X-MEDIA:" from mattering to
 * "#EXT-X-MEDIA-SEQUENCE". */
static const char *m3u8_tag(const char *line, const char *tag)
{
    size_t n = strlen(tag);
    if (strncmp(line, tag, n) != 0) return nullptr;
    if (line[n] == ':')  return line + n + 1;
    if (line[n] == '\0') return line + n;
    return nullptr;
}

/* Find attribute `name` in a comma-separated KEY=value list; copy its value
 * (surrounding quotes stripped, silently truncated to valsz-1) into val.
 * Quoted values may contain commas (CODECS="mp4a.40.5,avc1.4d401f") — the
 * splitter honors quotes.  Name match is ASCII case-insensitive (tolerant).
 * Returns false (val untouched) when the attribute is absent. */
static bool m3u8_attr(const char *list, const char *name,
                      char *val, size_t valsz)
{
    size_t nlen = strlen(name);
    const char *p = list;
    while (*p != '\0') {
        while (*p == ',' || *p == ' ' || *p == '\t') p++;
        if (*p == '\0') break;
        const char *key = p;
        while (*p != '\0' && *p != '=' && *p != ',') p++;
        if (*p != '=') continue;            /* valueless token — resync at ',' */
        size_t klen = (size_t)(p - key);
        p++;
        const char *v = p;
        size_t vlen;
        if (*p == '"') {
            v = ++p;
            while (*p != '\0' && *p != '"') p++;
            vlen = (size_t)(p - v);
            if (*p == '"') p++;             /* unterminated quote tolerated */
        } else {
            while (*p != '\0' && *p != ',') p++;
            vlen = (size_t)(p - v);
        }
        if (klen == nlen && ascii_nieq(key, name, nlen)) {
            if (vlen >= valsz) vlen = valsz - 1;
            memcpy(val, v, vlen);
            val[vlen] = '\0';
            return true;
        }
    }
    return false;
}

/* ── the parser ──────────────────────────────────────────────────────────── */

/* Line walk over the NUL-split buffer: start of next line = past this line's
 * first NUL.  Trimmed trailers read as extra empty lines and are skipped. */
#define M3U8_FOREACH_LINE(p, b, blen) \
    for (char *p = (b); p < (b) + (blen); p += strlen(p) + 1)

static char *m3u8_lstrip(char *p)
{
    while (*p == ' ' || *p == '\t') p++;
    return p;
}

rae_err rae_m3u8_parse(const char *text, size_t len, rae_m3u8 *out)
{
    if (out == nullptr) {
        rae_logf("m3u8: parse called with NULL out");
        return RAE_E_INVALID;
    }
    memset(out, 0, sizeof *out);
    if (text == nullptr) {
        rae_logf("m3u8: parse called with NULL text");
        return RAE_E_INVALID;
    }
    if (len == SIZE_MAX) {                  /* len+1 below would wrap */
        rae_logf("m3u8: absurd playlist length %zu", len);
        return RAE_E_INVALID;
    }

    char *buf = malloc(len + 1);
    if (buf == nullptr) {
        rae_logf("m3u8: out of memory copying %zu-byte playlist", len);
        return RAE_E_OOM;
    }
    memcpy(buf, text, len);
    buf[len] = '\0';

    char  *b    = buf;
    size_t blen = len;
    if (blen >= 3 && (unsigned char)b[0] == 0xEF &&
        (unsigned char)b[1] == 0xBB && (unsigned char)b[2] == 0xBF) {
        b += 3;                             /* skip UTF-8 BOM */
        blen -= 3;
    }

    /* split on '\n' into NUL-terminated lines, trimming trailing [ \t\r] */
    size_t ls = 0;
    for (size_t i = 0; i < blen; i++) {
        if (b[i] != '\n') continue;
        size_t e = i;
        b[e] = '\0';
        while (e > ls && (b[e-1] == ' ' || b[e-1] == '\t' || b[e-1] == '\r'))
            b[--e] = '\0';
        ls = i + 1;
    }
    {   /* last line, when the text has no trailing newline */
        size_t e = blen;
        while (e > ls && (b[e-1] == ' ' || b[e-1] == '\t' || b[e-1] == '\r'))
            b[--e] = '\0';
    }

    rae_err err = RAE_OK;

    /* pass 1: header check, kind, tag counts */
    size_t n_stream = 0, n_inf = 0;
    bool   saw_first = false;
    M3U8_FOREACH_LINE(p, b, blen) {
        const char *line = m3u8_lstrip(p);
        if (*line == '\0') continue;
        if (!saw_first) {
            saw_first = true;
            if (m3u8_tag(line, "#EXTM3U") == nullptr) {
                rae_logf("m3u8: first line is not #EXTM3U (got \"%.32s\")", line);
                err = RAE_E_PLAYLIST;
                goto done;
            }
            continue;
        }
        if      (m3u8_tag(line, "#EXT-X-STREAM-INF") != nullptr) n_stream++;
        else if (m3u8_tag(line, "#EXTINF")           != nullptr) n_inf++;
        if (n_stream > 256 || n_inf > 4096) {
            rae_logf("playlist exceeds 256 variants or 4096 segments");
            err = RAE_E_PLAYLIST;
            goto done;
        }
        if (m3u8_tag(line, "#EXT-X-BYTERANGE") || m3u8_tag(line, "#EXT-X-I-FRAMES-ONLY")) {
            rae_logf("byte-range and I-frame playlists are unsupported");
            err = RAE_E_UNSUPPORTED;
            goto done;
        }
    }
    if (!saw_first) {
        rae_logf("m3u8: empty playlist (%zu bytes, no non-blank line)", len);
        err = RAE_E_PLAYLIST;
        goto done;
    }
    if (n_stream > 0 && n_inf > 0) {
        rae_logf("m3u8: both #EXT-X-STREAM-INF (%zu) and #EXTINF (%zu) — mixed kinds",
                 n_stream, n_inf);
        err = RAE_E_PLAYLIST;
        goto done;
    }
    if (n_stream == 0 && n_inf == 0) {
        rae_logf("m3u8: neither #EXT-X-STREAM-INF nor #EXTINF — not a master or media playlist");
        err = RAE_E_PLAYLIST;
        goto done;
    }

    /* pass 2: fill */
    if (n_stream > 0) {
        out->kind     = RAE_M3U8_MASTER;
        out->variants = malloc(n_stream * sizeof *out->variants);
        if (out->variants == nullptr) {
            rae_logf("m3u8: out of memory (%zu variants)", n_stream);
            err = RAE_E_OOM;
            goto done;
        }
        bool     pending = false;
        uint32_t bw      = 0;
        char     codecs[sizeof out->variants[0].codecs];
        codecs[0] = '\0';
        M3U8_FOREACH_LINE(p, b, blen) {
            char *line = m3u8_lstrip(p);
            if (*line == '\0') continue;
            if (line[0] == '#') {
                const char *v = m3u8_tag(line, "#EXT-X-STREAM-INF");
                if (v != nullptr) {
                    char num[24];
                    bw = 0;
                    if (m3u8_attr(v, "BANDWIDTH", num, sizeof num))
                        bw = (uint32_t)strtoul(num, nullptr, 10);
                    if (!m3u8_attr(v, "CODECS", codecs, sizeof codecs))
                        codecs[0] = '\0';
                    pending = true;
                }
                continue;                   /* other tags / comments ignored */
            }
            if (!pending) continue;         /* stray URI with no STREAM-INF */
            size_t ulen = strlen(line);
            if (ulen >= RAE_URL_MAX) {
                rae_logf("m3u8: variant URI is %zu bytes (max %d)",
                         ulen, RAE_URL_MAX - 1);
                err = RAE_E_FORMAT;
                goto done;
            }
            rae_m3u8_variant *var = &out->variants[out->variant_count++];
            *var = (rae_m3u8_variant){0};
            var->bandwidth = bw;
            strcpy(var->codecs, codecs);
            memcpy(var->uri, line, ulen + 1);
            pending = false;
        }
        if (out->variant_count == 0) {
            rae_logf("m3u8: master playlist has #EXT-X-STREAM-INF but no variant URI lines");
            err = RAE_E_PLAYLIST;
            goto done;
        }
    } else {
        out->kind     = RAE_M3U8_MEDIA;
        out->segments = malloc(n_inf * sizeof *out->segments);
        if (out->segments == nullptr) {
            rae_logf("m3u8: out of memory (%zu segments)", n_inf);
            err = RAE_E_OOM;
            goto done;
        }
        bool   pending = false, disc = false, have_target = false;
        double dur = 0.0, max_dur = 0.0, target = 0.0;
        M3U8_FOREACH_LINE(p, b, blen) {
            char *line = m3u8_lstrip(p);
            if (*line == '\0') continue;
            if (line[0] == '#') {
                const char *v;
                if ((v = m3u8_tag(line, "#EXTINF")) != nullptr) {
                    dur = strtod(v, nullptr);
                    if (!(dur > 0.0)) dur = 0.0;        /* NaN/negative/garbage */
                    if (dur > max_dur) max_dur = dur;
                    pending = true;
                } else if ((v = m3u8_tag(line, "#EXT-X-TARGETDURATION")) != nullptr) {
                    target = strtod(v, nullptr);
                    have_target = target > 0.0;         /* unparsable ⇒ absent */
                } else if ((v = m3u8_tag(line, "#EXT-X-MEDIA-SEQUENCE")) != nullptr) {
                    out->media_sequence = strtoull(v, nullptr, 10);
                } else if (m3u8_tag(line, "#EXT-X-ENDLIST") != nullptr) {
                    out->endlist = true;
                } else if (m3u8_tag(line, "#EXT-X-DISCONTINUITY") != nullptr) {
                    disc = true;                        /* applies to next URI */
                } else if ((v = m3u8_tag(line, "#EXT-X-KEY")) != nullptr) {
                    if (!m3u8_attr(v, "METHOD",
                                   out->key_method, sizeof out->key_method) ||
                            strcmp(out->key_method, "NONE") != 0) {
                        rae_logf("encrypted HLS segments are unsupported");
                        err = RAE_E_UNSUPPORTED;
                        goto done;
                    }
                } else if (m3u8_tag(line, "#EXT-X-MAP") != nullptr) {
                    out->has_map = true;    /* fMP4 marker — consumer rejects in M0 */
                }
                continue;
            }
            if (!pending) continue;         /* stray URI with no EXTINF */
            size_t ulen = strlen(line);
            if (ulen >= RAE_URL_MAX) {
                rae_logf("m3u8: segment URI is %zu bytes (max %d)",
                         ulen, RAE_URL_MAX - 1);
                err = RAE_E_FORMAT;
                goto done;
            }
            rae_m3u8_segment *seg = &out->segments[out->segment_count++];
            *seg = (rae_m3u8_segment){0};
            seg->duration      = dur;
            seg->discontinuity = disc;
            memcpy(seg->uri, line, ulen + 1);
            pending = false;
            disc    = false;
        }
        if (out->segment_count == 0) {
            rae_logf("m3u8: media playlist has #EXTINF but no segment URI lines");
            err = RAE_E_PLAYLIST;
            goto done;
        }
        out->target_duration = have_target ? target
                             : (max_dur > 0.0 ? max_dur : 6.0);
        if (out->target_duration < 1.0)     /* floor enforced per header */
            out->target_duration = 1.0;
        if (out->target_duration > 60.0)    /* ceiling enforced per header:
                                               this is NETWORK data — a
                                               hostile/absurd value (1e999 ⇒
                                               +inf) must not be able to
                                               freeze the consumer's refresh
                                               cadence (hls converts it to an
                                               integer millisecond wait)     */
            out->target_duration = 60.0;
    }

done:
    free(buf);
    if (err != RAE_OK) {
        rae_m3u8_free(out);
        memset(out, 0, sizeof *out);
    }
    return err;
}

void rae_m3u8_free(rae_m3u8 *p)
{
    if (p == nullptr) return;
    free(p->variants);
    p->variants      = nullptr;
    p->variant_count = 0;
    free(p->segments);
    p->segments      = nullptr;
    p->segment_count = 0;
}

/* ── URL join (RFC 3986 resolution, the subset live HLS needs) ───────────── */

/* base must be scheme://authority…  On success *colon points at the ':' after
 * the scheme and *auth_end at the first of "/?#" past the authority (or the
 * terminating NUL). */
static bool url_parse_base(const char *base,
                           const char **colon, const char **auth_end)
{
    const char *s = base;
    if (!ascii_alpha(*s)) return false;
    s++;
    while (ascii_scheme_char(*s)) s++;
    if (s[0] != ':' || s[1] != '/' || s[2] != '/') return false;
    const char *a = s + 3;
    if (*a == '\0' || *a == '/' || *a == '?' || *a == '#') return false;  /* empty host */
    const char *ae = a;
    while (*ae != '\0' && *ae != '/' && *ae != '?' && *ae != '#') ae++;
    *colon    = s;
    *auth_end = ae;
    return true;
}

/* ':' before any '/' '?' '#' (and not first char) ⇒ rel carries a scheme. */
static bool url_has_scheme(const char *u)
{
    for (const char *p = u; *p != '\0'; p++) {
        if (*p == ':') return p != u;
        if (*p == '/' || *p == '?' || *p == '#') return false;
    }
    return false;
}

/* out = prefix[0..plen) + (slash ? "/" : "") + rel, bounds-checked. */
static rae_err url_emit(char out[RAE_URL_MAX], const char *prefix, size_t plen,
                        bool slash, const char *rel)
{
    size_t rlen  = strlen(rel);
    size_t total = plen + (slash ? 1u : 0u) + rlen;
    if (total >= RAE_URL_MAX) {
        rae_logf("url_join: result is %zu bytes (max %d)", total, RAE_URL_MAX - 1);
        out[0] = '\0';
        return RAE_E_FORMAT;
    }
    memcpy(out, prefix, plen);
    if (slash) out[plen++] = '/';
    memcpy(out + plen, rel, rlen + 1);
    return RAE_OK;
}

rae_err rae_url_join(const char *base, const char *rel, char out[RAE_URL_MAX])
{
    if (base == nullptr || rel == nullptr || out == nullptr) {
        rae_logf("url_join: NULL %s",
                 base == nullptr ? "base" : rel == nullptr ? "rel" : "out");
        if (out != nullptr) out[0] = '\0';
        return RAE_E_INVALID;
    }
    const char *colon, *auth_end;
    if (!url_parse_base(base, &colon, &auth_end)) {
        rae_logf("url_join: base is not an absolute URL: \"%.96s\"", base);
        out[0] = '\0';
        return RAE_E_INVALID;
    }

    if (rel[0] == '\0')                               /* "" → base itself */
        return url_emit(out, base, strlen(base), false, "");
    if (url_has_scheme(rel))                          /* absolute → rel itself */
        return url_emit(out, rel, strlen(rel), false, "");
    if (rel[0] == '/' && rel[1] == '/')               /* scheme-relative */
        return url_emit(out, base, (size_t)(colon - base) + 1, false, rel);
    if (rel[0] == '/')                                /* authority-relative */
        return url_emit(out, base, (size_t)(auth_end - base), false, rel);

    /* path-relative: base truncated after the last '/' of its PATH (query and
     * fragment of base dropped); a base with no path contributes just "/". */
    if (*auth_end != '/')
        return url_emit(out, base, (size_t)(auth_end - base), true, rel);
    const char *pe = auth_end;
    while (*pe != '\0' && *pe != '?' && *pe != '#') pe++;
    const char *last = pe - 1;                        /* path starts at '/', so */
    while (*last != '/') last--;                      /* this walk is bounded   */
    return url_emit(out, base, (size_t)(last - base) + 1, false, rel);
}
