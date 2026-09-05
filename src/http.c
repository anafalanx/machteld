/* http.c -- `http get|post`: an HTTPS-capable client, over Windows' own stack.
 *
 * WHY THIS IS NOT A TLS IMPLEMENTATION. The obvious way to reach https from Tcl
 * is `package require tls` over a stacked channel -- a TLS record layer, a
 * handshake state machine, buffer management and renegotiation, roughly a
 * thousand lines of subtle C. This project has just finished paying for a
 * hand-written reparse-payload parser whose bounds check was twelve bytes short
 * and which segfaulted under a proof-of-concept; writing a crypto transport by
 * hand, in the same language, in the same month, would be learning nothing.
 *
 * WinHTTP is Windows' own HTTP client and it already contains all of it:
 * certificate chain validation against the machine's trust store, TLS version
 * negotiation, redirects, proxy discovery, chunked transfer decoding,
 * keep-alive and authentication. It is serviced by Windows Update rather than
 * by a rebuild here, which means a TLS advisory is Microsoft's problem and not
 * this exe's. The OS ships the hard part, so use it.
 *
 * WHAT THIS COSTS, said plainly rather than discovered later: `package require
 * tls` still fails, so Tcl code written against the `http`+`tls` idiom does not
 * run here. This verb is Machteld's deliberately narrow API: a request in and a
 * structured result out, with the TLS implementation left to Windows.
 *
 * NO `-insecure`. There is no option to skip certificate validation. Every such
 * flag is eventually left on in something that matters, and a caller who really
 * needs an unverified endpoint has `run -- curl` and has to say so out loud.
 */

#include "machteld.h"

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <windows.h>
#include <winhttp.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <wchar.h>
#include <limits.h>

/* A body cap that exists so a runaway response cannot become a runaway
 * allocation. 64 MB by default, and `-maxbody` moves it; a response that
 * exceeds it fails rather than being silently truncated, because a truncated
 * body that looks complete is the failure this whole codebase is built to
 * refuse. */
#define HTTP_MAXBODY_DEFAULT (64u * 1024u * 1024u)
#define HTTP_READ_CHUNK      65536u

static int http_error(Tcl_Interp *interp, const char *code, const char *msg) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "HTTP", code, (char *)NULL);
    return TCL_ERROR;
}

/* The Win32 code travels with the message for the same reason it does in
 * dirs.c: the message cannot be trapped on, and at this layer it does not
 * discriminate -- a refused connection and a DNS failure both arrive as prose. */
static int http_win_error(Tcl_Interp *interp, const char *code, const char *what, DWORD e) {
    char buf[256];
    snprintf(buf, sizeof buf, "%s: win32 %lu", what, (unsigned long)e);
    Tcl_SetObjResult(interp, Tcl_NewStringObj(buf, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "HTTP", code, (char *)NULL);
    return TCL_ERROR;
}

static wchar_t *http_wide(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (w == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            s, -1, w, n) <= 0) {
        free(w);
        return NULL;
    }
    return w;
}

static char *http_utf8(const wchar_t *w, int wlen) {
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                w, wlen, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *s = (char *)malloc((size_t)n + 1);
    if (s == NULL) return NULL;
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
            w, wlen, s, n, NULL, NULL) <= 0) {
        free(s);
        return NULL;
    }
    s[n] = '\0';
    return s;
}

/* --- the response headers ---------------------------------------------------
 *
 * RAW AND COOKED, BOTH. `headers` is a dict with lower-cased names, which is
 * what a caller wants nine times in ten -- and a dict cannot hold `Set-Cookie`
 * twice, so a repeat is joined with ", " as RFC 9110 permits for list-valued
 * fields. That is lossy for `Set-Cookie` specifically, so `rawheaders` carries
 * the original block verbatim and nothing is actually lost. Convenience that
 * silently discards data would be the wrong half of the trade; convenience
 * beside the original is not. */
static int http_put_header(Tcl_Obj *d, const char *line, size_t len) {
    const char *colon = memchr(line, ':', len);
    if (colon == NULL || colon == line) return 1;
    size_t nlen = (size_t)(colon - line);
    const char *v = colon + 1;
    size_t vlen = len - nlen - 1;
    while (vlen > 0 && (*v == ' ' || *v == '\t')) { v++; vlen--; }

    char *name = (char *)malloc(nlen + 1);
    if (name == NULL) return 0;
    for (size_t i = 0; i < nlen; i++) {
        name[i] = (line[i] >= 'A' && line[i] <= 'Z') ? (char)(line[i] - 'A' + 'a') : line[i];
    }
    name[nlen] = '\0';

    Tcl_Obj *key = Tcl_NewStringObj(name, (Tcl_Size)nlen);
    free(name);
    /* Tcl retains only the key object it stores; a repeated header would
     * otherwise leak this one. */
    Tcl_IncrRefCount(key);
    Tcl_Obj *prev = NULL;
    Tcl_DictObjGet(NULL, d, key, &prev);
    if (prev == NULL) {
        Tcl_DictObjPut(NULL, d, key, Tcl_NewStringObj(v, (Tcl_Size)vlen));
    } else {
        Tcl_Obj *joined = Tcl_DuplicateObj(prev);
        Tcl_AppendToObj(joined, ", ", 2);
        Tcl_AppendToObj(joined, v, (Tcl_Size)vlen);
        Tcl_DictObjPut(NULL, d, key, joined);
    }
    Tcl_DecrRefCount(key);
    return 1;
}

typedef struct {
    Tcl_WideInt timeout;        /* ms */
    Tcl_WideInt maxbody;
    const char *agent;
    Tcl_Obj    *headers;        /* dict, caller's -- borrowed, never freed here */
    const char *type;           /* -type: Content-Type for a body */
    int         has_content_type;
    int         redirect_none;  /* -redirect none: return the first 3xx */
} HttpOpts;

static int http_text_safe(Tcl_Obj *obj, int header_name) {
    Tcl_Size n;
    const char *s = Tcl_GetStringFromObj(obj, &n);
    if (n == 0 && header_name) return 0;
    for (Tcl_Size i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '\0' || c == '\r' || c == '\n') return 0;
        if (header_name && (c == ':' || c <= 0x20 || c == 0x7f)) return 0;
    }
    return 1;
}

static int http_u64(const char *s, const char **end, unsigned long long *out) {
    if (*s < '0' || *s > '9') return 0;
    unsigned long long n = 0;
    do {
        unsigned digit = (unsigned)(*s - '0');
        if (n > (ULLONG_MAX - digit) / 10u) return 0;
        n = n * 10u + digit;
        s++;
    } while (*s >= '0' && *s <= '9');
    *end = s;
    *out = n;
    return 1;
}

static int http_duration(Tcl_Interp *interp, Tcl_Obj *obj, Tcl_WideInt *out) {
    if (!http_text_safe(obj, 0)) {
        return http_error(interp, "badvalue", "-timeout contains NUL or a newline");
    }
    const char *end;
    unsigned long long n, factor;
    if (!http_u64(Tcl_GetString(obj), &end, &n)) {
        return http_error(interp, "badvalue", "-timeout takes an integer duration like 30s");
    }
    if (strcmp(end, "ms") == 0) factor = 1u;
    else if (strcmp(end, "s") == 0) factor = 1000u;
    else if (strcmp(end, "m") == 0) factor = 60000u;
    else if (strcmp(end, "h") == 0) factor = 3600000u;
    else return http_error(interp, "badvalue", "-timeout needs a unit: ms, s, m or h");
    if (n == 0 || n > (unsigned long long)INT_MAX / factor) {
        return http_error(interp, "badvalue", "-timeout is outside WinHTTP's supported range");
    }
    *out = (Tcl_WideInt)(n * factor);
    return TCL_OK;
}

static int http_size(Tcl_Interp *interp, Tcl_Obj *obj, Tcl_WideInt *out) {
    if (!http_text_safe(obj, 0)) {
        return http_error(interp, "badvalue", "-maxbody contains NUL or a newline");
    }
    const char *end;
    unsigned long long n, factor = 1u;
    if (!http_u64(Tcl_GetString(obj), &end, &n)) {
        return http_error(interp, "badvalue", "-maxbody takes a positive byte count like 8M");
    }
    if (*end == 'K' || *end == 'k') { factor = 1ull << 10; end++; }
    else if (*end == 'M' || *end == 'm') { factor = 1ull << 20; end++; }
    else if (*end == 'G' || *end == 'g') { factor = 1ull << 30; end++; }
    if (*end == 'B' || *end == 'b') end++;
    if (*end != '\0' || n == 0 ||
            n > (unsigned long long)TCL_SIZE_MAX / factor) {
        return http_error(interp, "badvalue", "-maxbody is outside the supported range");
    }
    *out = (Tcl_WideInt)(n * factor);
    return TCL_OK;
}

static int http_header_is(Tcl_Obj *obj, const char *expected) {
    Tcl_Size n;
    const char *s = Tcl_GetStringFromObj(obj, &n);
    size_t want = strlen(expected);
    if (n != (Tcl_Size)want) return 0;
    for (size_t i = 0; i < want; i++) {
        char c = s[i];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        if (c != expected[i]) return 0;
    }
    return 1;
}

static int http_opts(Tcl_Interp *interp, int objc, Tcl_Obj *const objv[], int first,
                     int allow_type, HttpOpts *o) {
    o->timeout = 30000;
    o->maxbody = (Tcl_WideInt)HTTP_MAXBODY_DEFAULT;
    o->agent   = "machteld";
    o->headers = NULL;
    o->type    = NULL;
    o->has_content_type = 0;
    o->redirect_none = 0;
    for (int i = first; i < objc; i++) {
        const char *a = Tcl_GetString(objv[i]);
        if (i + 1 >= objc) return http_error(interp, "usage", "option needs a value");
        Tcl_Obj *v = objv[++i];
        if (strcmp(a, "-timeout") == 0) {
            if (http_duration(interp, v, &o->timeout) != TCL_OK) return TCL_ERROR;
            continue;
        }
        if (strcmp(a, "-redirect") == 0) {
            /* Exactly `none` (plan-machteld-015 H1): the first 3xx returns
             * normally, Location included, and NO second request is ever
             * issued - so no caller header or body is forwarded anywhere,
             * with nothing to guess about which headers are "sensitive".
             * Other policies need their own consumer and review. */
            if (strcmp(Tcl_GetString(v), "none") != 0) {
                return http_error(interp, "badvalue", "-redirect takes exactly \"none\"");
            }
            o->redirect_none = 1;
            continue;
        }
        if (strcmp(a, "-maxbody") == 0) {
            if (http_size(interp, v, &o->maxbody) != TCL_OK) return TCL_ERROR;
            continue;
        }
        if (strcmp(a, "-agent") == 0) {
            if (!http_text_safe(v, 0)) return http_error(interp, "badvalue", "-agent contains a forbidden newline or NUL");
            o->agent = Tcl_GetString(v); continue;
        }
        if (strcmp(a, "-type")  == 0) {
            if (!allow_type) return http_error(interp, "usage", "-type is only valid for http post");
            if (!http_text_safe(v, 0)) return http_error(interp, "badvalue", "-type contains a forbidden newline or NUL");
            o->type = Tcl_GetString(v); continue;
        }
        if (strcmp(a, "-headers") == 0) {
            Tcl_Size n;
            if (Tcl_DictObjSize(interp, v, &n) != TCL_OK) {
                return http_error(interp, "badvalue", "-headers takes a dict");
            }
            Tcl_DictSearch search;
            Tcl_Obj *key, *value;
            int done;
            if (Tcl_DictObjFirst(interp, v, &search, &key, &value, &done) != TCL_OK) {
                return http_error(interp, "badvalue", "-headers takes a dict");
            }
            /* A later -headers replaces the earlier dict, so its Content-Type
             * fact must not survive into the replacement. */
            o->has_content_type = 0;
            for (; !done; Tcl_DictObjNext(&search, &key, &value, &done)) {
                if (!http_text_safe(key, 1) || !http_text_safe(value, 0)) {
                    Tcl_DictObjDone(&search);
                    return http_error(interp, "badvalue", "header names and values may not contain controls, colon, newline, or NUL");
                }
                if (http_header_is(key, "content-type")) o->has_content_type = 1;
            }
            Tcl_DictObjDone(&search);
            o->headers = v;
            continue;
        }
        return http_error(interp, "usage", "unknown option");
    }
    return TCL_OK;
}

/* Everything the request owns, in one place, so the single cleanup label below
 * can release it whatever went wrong. */
typedef struct {
    HINTERNET session, conn, req;
    wchar_t  *wurl, *whost, *wpath, *wverb, *wagent, *whdrs;
    char     *body;
} HttpReq;

static void http_cleanup(HttpReq *r) {
    if (r->req)     WinHttpCloseHandle(r->req);
    if (r->conn)    WinHttpCloseHandle(r->conn);
    if (r->session) WinHttpCloseHandle(r->session);
    free(r->wurl); free(r->whost); free(r->wpath);
    free(r->wverb); free(r->wagent); free(r->whdrs);
    free(r->body);
}

/* Every WinHTTP failure class that is about the certificate or the secure
 * channel is `tls`, not only the umbrella SECURE_FAILURE code, so a caller
 * trapping tls sees the whole family. */
static int http_is_tls_error(DWORD e) {
    switch (e) {
        case ERROR_WINHTTP_SECURE_FAILURE:
        case ERROR_WINHTTP_SECURE_CERT_CN_INVALID:
        case ERROR_WINHTTP_SECURE_CERT_DATE_INVALID:
        case ERROR_WINHTTP_SECURE_CERT_REV_FAILED:
        case ERROR_WINHTTP_SECURE_CERT_REVOKED:
        case ERROR_WINHTTP_SECURE_CERT_WRONG_USAGE:
        case ERROR_WINHTTP_SECURE_CHANNEL_ERROR:
        case ERROR_WINHTTP_SECURE_INVALID_CA:
        case ERROR_WINHTTP_SECURE_INVALID_CERT:
        case ERROR_WINHTTP_CLIENT_CERT_NO_PRIVATE_KEY:
        case ERROR_WINHTTP_CLIENT_CERT_NO_ACCESS_PRIVATE_KEY:
            return 1;
        default:
            return 0;
    }
}

static int http_request_error(Tcl_Interp *interp, DWORD e, const char *what) {
    if (http_is_tls_error(e)) {
        return http_win_error(interp, "tls", "the secure connection was refused", e);
    }
    if (e == ERROR_WINHTTP_TIMEOUT) {
        return http_win_error(interp, "timeout", what, e);
    }
    if (e == ERROR_WINHTTP_NAME_NOT_RESOLVED || e == ERROR_WINHTTP_CANNOT_CONNECT) {
        return http_win_error(interp, "notfound", "cannot reach the host", e);
    }
    return http_win_error(interp, "oserror", what, e);
}

static int http_do(Tcl_Interp *interp, const char *verb, const char *url,
                   const unsigned char *body, Tcl_Size bodylen, HttpOpts *o) {
    HttpReq r;
    memset(&r, 0, sizeof r);

    if (bodylen < 0 || (unsigned long long)bodylen > MAXDWORD) {
        return http_error(interp, "toobig", "the request body exceeds WinHTTP's size limit");
    }

    r.wurl   = http_wide(url);
    r.wverb  = http_wide(verb);
    r.wagent = http_wide(o->agent);
    if (r.wurl == NULL || r.wverb == NULL || r.wagent == NULL) {
        http_cleanup(&r);
        return http_error(interp, "badvalue", "the url is not representable");
    }

    /* CRACK THE URL WITH WINDOWS' OWN PARSER, not a hand-rolled one: a URL
     * splitter is a security boundary, and the host is what the certificate is
     * checked against. */
    URL_COMPONENTS uc;
    memset(&uc, 0, sizeof uc);
    uc.dwStructSize = sizeof uc;
    uc.dwSchemeLength = uc.dwHostNameLength = uc.dwUrlPathLength = uc.dwExtraInfoLength = (DWORD)-1;
    if (!WinHttpCrackUrl(r.wurl, 0, 0, &uc)) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "badvalue", "the url could not be parsed", e);
    }
    if (uc.nScheme != INTERNET_SCHEME_HTTP && uc.nScheme != INTERNET_SCHEME_HTTPS) {
        http_cleanup(&r);
        return http_error(interp, "badvalue", "only http and https urls are supported");
    }

    r.whost = (wchar_t *)malloc(((size_t)uc.dwHostNameLength + 1) * sizeof(wchar_t));
    if (r.whost == NULL) { http_cleanup(&r); return http_error(interp, "oserror", "out of memory"); }
    memcpy(r.whost, uc.lpszHostName, (size_t)uc.dwHostNameLength * sizeof(wchar_t));
    r.whost[uc.dwHostNameLength] = L'\0';

    /* Path and query together, and an empty path means "/". */
    size_t plen = (size_t)uc.dwUrlPathLength + (size_t)uc.dwExtraInfoLength;
    r.wpath = (wchar_t *)malloc((plen + 2) * sizeof(wchar_t));
    if (r.wpath == NULL) { http_cleanup(&r); return http_error(interp, "oserror", "out of memory"); }
    if (plen == 0) {
        wcscpy(r.wpath, L"/");
    } else {
        memcpy(r.wpath, uc.lpszUrlPath, plen * sizeof(wchar_t));
        r.wpath[plen] = L'\0';
        wchar_t *fragment = wcschr(r.wpath, L'#');
        if (fragment != NULL) *fragment = L'\0';
        if (r.wpath[0] == L'\0') wcscpy(r.wpath, L"/");
        else if (r.wpath[0] == L'?') {
            size_t current = wcslen(r.wpath);
            memmove(r.wpath + 1, r.wpath,
                    (current + 1) * sizeof(wchar_t));
            r.wpath[0] = L'/';
        }
    }

    r.session = WinHttpOpen(r.wagent, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                            WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (r.session == NULL) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "oserror", "cannot open an http session", e);
    }
    int t = (int)o->timeout;
    if (!WinHttpSetTimeouts(r.session, t, t, t, t)) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "oserror", "cannot configure http timeouts", e);
    }
    /* WinHttpSetTimeouts' receive value governs socket reads, but WinHTTP has
     * a separate (90-second by default) deadline for receiving the complete
     * response headers. The per-request options below make both inherited
     * receive clocks explicit; either phase then reports ERROR_WINHTTP_TIMEOUT
     * through http_request_error below. */
    /* Omitted-option behavior is untouched: follow, but never HTTPS->HTTP.
     * Under -redirect none WinHTTP is told to follow NOTHING, so the first
     * 3xx response is returned to the caller as an ordinary response. */
    DWORD redirect_policy = o->redirect_none
        ? WINHTTP_OPTION_REDIRECT_POLICY_NEVER
        : WINHTTP_OPTION_REDIRECT_POLICY_DISALLOW_HTTPS_TO_HTTP;
    if (!WinHttpSetOption(r.session, WINHTTP_OPTION_REDIRECT_POLICY,
            &redirect_policy, sizeof redirect_policy)) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "oserror", "cannot configure redirect policy", e);
    }

    /* WinHttpConnect does not touch the network; a failure here is a bad
     * handle or parameter, never an unreachable host. */
    r.conn = WinHttpConnect(r.session, r.whost, uc.nPort, 0);
    if (r.conn == NULL) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "oserror", "cannot create the connection handle", e);
    }

    DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    r.req = WinHttpOpenRequest(r.conn, r.wverb, r.wpath, NULL,
                               WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (r.req == NULL) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "oserror", "cannot build the request", e);
    }
    DWORD receive_timeout = (DWORD)t;
    if (!WinHttpSetOption(r.req, WINHTTP_OPTION_RECEIVE_TIMEOUT,
            &receive_timeout, sizeof receive_timeout)) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "oserror", "cannot configure the receive timeout", e);
    }
    DWORD response_timeout = (DWORD)t;
    if (!WinHttpSetOption(r.req, WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT,
            &response_timeout, sizeof response_timeout)) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "oserror", "cannot configure the response timeout", e);
    }

    /* The caller's headers, plus a Content-Type when a body was given and no
     * explicit type was. */
    Tcl_Obj *hdrbuf = Tcl_NewObj();
    Tcl_IncrRefCount(hdrbuf);
    if (o->headers != NULL) {
        Tcl_DictSearch s;
        Tcl_Obj *k, *v;
        int done;
        if (Tcl_DictObjFirst(interp, o->headers, &s, &k, &v, &done) != TCL_OK) {
            Tcl_DecrRefCount(hdrbuf);
            http_cleanup(&r);
            return TCL_ERROR;
        }
        for (; !done; Tcl_DictObjNext(&s, &k, &v, &done)) {
            Tcl_AppendObjToObj(hdrbuf, k);
            Tcl_AppendToObj(hdrbuf, ": ", 2);
            Tcl_AppendObjToObj(hdrbuf, v);
            Tcl_AppendToObj(hdrbuf, "\r\n", 2);
        }
        Tcl_DictObjDone(&s);
    }
    if (o->type != NULL) {
        Tcl_AppendToObj(hdrbuf, "Content-Type: ", -1);
        Tcl_AppendToObj(hdrbuf, o->type, -1);
        Tcl_AppendToObj(hdrbuf, "\r\n", 2);
    }
    Tcl_Size hlen;
    const char *hstr = Tcl_GetStringFromObj(hdrbuf, &hlen);
    if (hlen > 0) {
        r.whdrs = http_wide(hstr);
        if (r.whdrs == NULL ||
                !WinHttpAddRequestHeaders(r.req, r.whdrs, (DWORD)-1,
                    WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE)) {
            DWORD e = GetLastError();
            Tcl_DecrRefCount(hdrbuf);
            http_cleanup(&r);
            return http_win_error(interp, "badvalue", "the request headers were refused", e);
        }
    }
    Tcl_DecrRefCount(hdrbuf);

    if (!WinHttpSendRequest(r.req, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            (LPVOID)body, (DWORD)bodylen, (DWORD)bodylen, 0)) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_request_error(interp, e, "the request failed");
    }
    if (!WinHttpReceiveResponse(r.req, NULL)) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_request_error(interp, e, "the response could not be received");
    }

    DWORD status = 0, slen = sizeof status;
    if (!WinHttpQueryHeaders(r.req,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX, &status, &slen,
            WINHTTP_NO_HEADER_INDEX)) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "oserror", "cannot read the response status", e);
    }

    /* Raw headers: asked for its size first, the same discipline as every other
     * sized Win32 query in this codebase. */
    DWORD rawlen = 0;
    if (WinHttpQueryHeaders(r.req, WINHTTP_QUERY_RAW_HEADERS_CRLF,
            WINHTTP_HEADER_NAME_BY_INDEX, NULL, &rawlen,
            WINHTTP_NO_HEADER_INDEX) || GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "oserror", "cannot size the response headers", e);
    }
    Tcl_Obj *hdict = Tcl_NewDictObj();
    Tcl_Obj *rawobj = Tcl_NewStringObj("", 0);
    Tcl_IncrRefCount(hdict);
    Tcl_IncrRefCount(rawobj);
    if (rawlen > 0) {
        wchar_t *raw = (wchar_t *)malloc(rawlen + sizeof(wchar_t));
        if (raw == NULL) {
            Tcl_DecrRefCount(hdict); Tcl_DecrRefCount(rawobj);
            http_cleanup(&r);
            return http_error(interp, "oserror", "out of memory reading response headers");
        }
        if (!WinHttpQueryHeaders(r.req, WINHTTP_QUERY_RAW_HEADERS_CRLF,
                WINHTTP_HEADER_NAME_BY_INDEX, raw, &rawlen,
                WINHTTP_NO_HEADER_INDEX)) {
            DWORD e = GetLastError();
            free(raw);
            Tcl_DecrRefCount(hdict); Tcl_DecrRefCount(rawobj);
            http_cleanup(&r);
            return http_win_error(interp, "oserror", "cannot read the response headers", e);
        }
        if ((rawlen % sizeof(wchar_t)) != 0) {
            free(raw);
            Tcl_DecrRefCount(hdict); Tcl_DecrRefCount(rawobj);
            http_cleanup(&r);
            return http_error(interp, "oserror", "the response headers have an invalid byte length");
        }
        raw[rawlen / sizeof(wchar_t)] = L'\0';
        char *u = http_utf8(raw, -1);
        free(raw);
        if (u == NULL) {
            Tcl_DecrRefCount(hdict); Tcl_DecrRefCount(rawobj);
            http_cleanup(&r);
            return http_error(interp, "oserror", "response headers are not representable");
        }
        Tcl_SetStringObj(rawobj, u, -1);
        /* Split on CRLF; the first line is the status line, which is not a
         * header and is skipped. */
        const char *p = u;
        int firstline = 1;
        while (*p) {
            const char *nl = strstr(p, "\r\n");
            size_t len = nl ? (size_t)(nl - p) : strlen(p);
            if (len > 0 && !firstline && !http_put_header(hdict, p, len)) {
                free(u);
                Tcl_DecrRefCount(hdict); Tcl_DecrRefCount(rawobj);
                http_cleanup(&r);
                return http_error(interp, "oserror", "out of memory reading response headers");
            }
            firstline = 0;
            if (nl == NULL) break;
            p = nl + 2;
        }
        free(u);
    }

    /* The body, grown geometrically and capped. */
    Tcl_WideInt cap = 0, used = 0;
    unsigned char *buf = NULL;
    for (;;) {
        DWORD avail = 0;
        if (!WinHttpQueryDataAvailable(r.req, &avail)) {
            DWORD e = GetLastError();
            free(buf);
            Tcl_DecrRefCount(hdict); Tcl_DecrRefCount(rawobj);
            http_cleanup(&r);
            return http_request_error(interp, e, "the response could not be read");
        }
        if (avail == 0) break;
        Tcl_WideInt chunk = (Tcl_WideInt)avail;
        if (used > o->maxbody - chunk) {
            free(buf);
            Tcl_DecrRefCount(hdict); Tcl_DecrRefCount(rawobj);
            http_cleanup(&r);
            /* REFUSED, NOT TRUNCATED. A short body that looks whole is the one
             * answer this codebase never gives. */
            return http_error(interp, "toobig",
                "the response exceeds -maxbody; choose a larger explicit cap");
        }
        if (used + chunk > cap) {
            Tcl_WideInt need = used + chunk;
            Tcl_WideInt ncap = cap ? cap : (Tcl_WideInt)HTTP_READ_CHUNK;
            if (ncap > o->maxbody) ncap = o->maxbody;
            while (ncap < need) {
                if (ncap > o->maxbody / 2) { ncap = need; break; }
                ncap *= 2;
            }
            unsigned char *g = (unsigned char *)realloc(buf, (size_t)ncap);
            if (g == NULL) {
                free(buf);
                Tcl_DecrRefCount(hdict); Tcl_DecrRefCount(rawobj);
                http_cleanup(&r);
                return http_error(interp, "oserror", "out of memory reading the response");
            }
            buf = g;
            cap = ncap;
        }
        DWORD got = 0;
        if (!WinHttpReadData(r.req, buf + used, avail, &got)) {
            DWORD e = GetLastError();
            free(buf);
            Tcl_DecrRefCount(hdict); Tcl_DecrRefCount(rawobj);
            http_cleanup(&r);
            return http_request_error(interp, e, "the response could not be read");
        }
        if (got == 0) break;
        used += (Tcl_WideInt)got;
    }

    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("status", -1), Tcl_NewWideIntObj((Tcl_WideInt)status));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("headers", -1), hdict);
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("rawheaders", -1), rawobj);
    /* A BYTE ARRAY, NOT A STRING. An HTTP body is bytes until something says
     * otherwise, and guessing an encoding here would corrupt every image and
     * mis-decode every page whose charset disagrees with the guess. Decode with
     * `encoding convertfrom` once the content-type has been read. */
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("body", -1),
                   Tcl_NewByteArrayObj(buf ? buf : (unsigned char *)"", (Tcl_Size)used));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("bytes", -1), Tcl_NewWideIntObj(used));
    Tcl_DecrRefCount(hdict);
    Tcl_DecrRefCount(rawobj);
    free(buf);
    http_cleanup(&r);
    Tcl_SetObjResult(interp, d);
    return TCL_OK;
}

static int HttpCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    static const char *const subs[] = { "get", "post", NULL };
    enum { H_GET, H_POST };
    int idx;
    if (objc < 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "get url ?options? | post url body "
                                          "?options? (options: -headers dict "
                                          "-timeout duration -agent name -maxbody "
                                          "size -redirect none; post only: -type mime)");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", TCL_EXACT, &idx) != TCL_OK) {
        return TCL_ERROR;
    }
    if (!http_text_safe(objv[2], 0)) {
        return http_error(interp, "badvalue", "the url contains NUL or a newline");
    }
    const char *url = Tcl_GetString(objv[2]);
    HttpOpts o;
    if (idx == H_GET) {
        if (http_opts(interp, objc, objv, 3, 0, &o) != TCL_OK) return TCL_ERROR;
        return http_do(interp, "GET", url, NULL, 0, &o);
    }
    if (objc < 4) {
        Tcl_WrongNumArgs(interp, 1, objv, "post url body ?options?");
        return TCL_ERROR;
    }
    if (http_opts(interp, objc, objv, 4, 1, &o) != TCL_OK) return TCL_ERROR;
    /* The body follows the runtime's value rule: a byte array sends its bytes,
     * any other value sends its UTF-8 string representation. Asking Tcl for the
     * bytes of a plain string returned NULL for a character above U+00FF and
     * Latin-1 bytes below it, neither of which is the JSON text the reference
     * example posts. The type is matched by name because Tcl 9 registers only
     * one of its two byte-array representations. */
    Tcl_Size blen;
    const unsigned char *b;
    const Tcl_ObjType *btype = objv[3]->typePtr;
    if (btype != NULL && strcmp(btype->name, "bytearray") == 0) {
        b = Tcl_GetByteArrayFromObj(objv[3], &blen);
        if (b == NULL) return http_error(interp, "badvalue", "the post body is not a byte array");
    } else {
        b = (const unsigned char *)Tcl_GetStringFromObj(objv[3], &blen);
    }
    if (o.type == NULL && !o.has_content_type) o.type = "application/octet-stream";
    return http_do(interp, "POST", url, b, blen, &o);
}

int Machteldhttp_Init(Tcl_Interp *interp) {
    if (Tcl_CreateObjCommand(interp, "::machteld::http", HttpCmd, NULL, NULL) == NULL) {
        return TCL_ERROR;
    }
    if (Tcl_PkgProvide(interp, "machteld::http", MACHTELD_VERSION) != TCL_OK) {
        Tcl_DeleteCommand(interp, "::machteld::http");
        return TCL_ERROR;
    }
    return TCL_OK;
}
