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
 * this exe's. Same reasoning that has `mirror` drive robocopy instead of
 * writing a copier: the OS ships the hard part, so use it.
 *
 * WHAT THIS COSTS, said plainly rather than discovered later: `package require
 * tls` still fails, so Tcl code written against the `http`+`tls` idiom does not
 * run here. This verb is machteld's own API -- a dict in, a dict out, like
 * everything else. That is the right trade for a personal toolkit and the wrong
 * one for a distribution, and machteld is deliberately the former.
 *
 * NO `-insecure`. There is no option to skip certificate validation. Every such
 * flag is eventually left on in something that matters, and a caller who really
 * needs an unverified endpoint has `run -- curl` and has to say so out loud.
 */

#include <tcl.h>

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <windows.h>
#include <winhttp.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <wchar.h>

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

/* NAMED `..._error` SO THE MANIFEST CAN SEE IT, and that is not cosmetic.
 * tools/genmanifest.tcl finds a verb's codes by matching a call to a function
 * whose name ends in `_error` with a literal code right after `interp`, so the
 * first version of this raiser -- called `http_oserr` -- hid `tls`, `timeout`
 * and `notfound` from the palette completely. The manifest published four codes
 * where the truth was seven: a verb under-reporting what it can throw, which is
 * exactly the false claim self-description exists to prevent. Caught by the
 * registry gate rather than by review.
 *
 * The Win32 code travels with the message for the same reason it does in
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
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (w == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n) <= 0) { free(w); return NULL; }
    return w;
}

static char *http_utf8(const wchar_t *w, int wlen) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w, wlen, NULL, 0, NULL, NULL);
    if (n < 0) return NULL;
    char *s = (char *)malloc((size_t)n + 1);
    if (s == NULL) return NULL;
    if (n > 0 && WideCharToMultiByte(CP_UTF8, 0, w, wlen, s, n, NULL, NULL) <= 0) {
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
static void http_put_header(Tcl_Obj *d, const char *line, size_t len) {
    const char *colon = memchr(line, ':', len);
    if (colon == NULL || colon == line) return;
    size_t nlen = (size_t)(colon - line);
    const char *v = colon + 1;
    size_t vlen = len - nlen - 1;
    while (vlen > 0 && (*v == ' ' || *v == '\t')) { v++; vlen--; }

    char *name = (char *)malloc(nlen + 1);
    if (name == NULL) return;
    for (size_t i = 0; i < nlen; i++) {
        name[i] = (line[i] >= 'A' && line[i] <= 'Z') ? (char)(line[i] - 'A' + 'a') : line[i];
    }
    name[nlen] = '\0';

    Tcl_Obj *key = Tcl_NewStringObj(name, (Tcl_Size)nlen);
    free(name);
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
}

typedef struct {
    Tcl_WideInt timeout;        /* ms */
    Tcl_WideInt maxbody;
    const char *agent;
    Tcl_Obj    *headers;        /* dict, caller's -- borrowed, never freed here */
    const char *type;           /* -type: Content-Type for a body */
} HttpOpts;

static int http_opts(Tcl_Interp *interp, int objc, Tcl_Obj *const objv[], int first,
                     HttpOpts *o) {
    o->timeout = 30000;
    o->maxbody = (Tcl_WideInt)HTTP_MAXBODY_DEFAULT;
    o->agent   = "machteld";
    o->headers = NULL;
    o->type    = NULL;
    for (int i = first; i < objc; i++) {
        const char *a = Tcl_GetString(objv[i]);
        if (i + 1 >= objc) return http_error(interp, "usage", "option needs a value");
        Tcl_Obj *v = objv[++i];
        if (strcmp(a, "-timeout") == 0) {
            /* Durations carry a unit here as everywhere else in the palette: a
             * bare number can never silently mean seconds. */
            const char *s = Tcl_GetString(v);
            char *end = NULL;
            double n = strtod(s, &end);
            if (end == s || n < 0) {
                return http_error(interp, "badvalue", "-timeout takes a duration like 30s");
            }
            if (strcmp(end, "ms") == 0)      o->timeout = (Tcl_WideInt)n;
            else if (strcmp(end, "s") == 0)  o->timeout = (Tcl_WideInt)(n * 1000);
            else if (strcmp(end, "m") == 0)  o->timeout = (Tcl_WideInt)(n * 60000);
            else return http_error(interp, "badvalue", "-timeout needs a unit: ms, s or m");
            continue;
        }
        if (strcmp(a, "-maxbody") == 0) {
            Tcl_WideInt n;
            if (Tcl_GetWideIntFromObj(NULL, v, &n) != TCL_OK || n <= 0) {
                return http_error(interp, "badvalue", "-maxbody takes a positive byte count");
            }
            o->maxbody = n;
            continue;
        }
        if (strcmp(a, "-agent") == 0) { o->agent = Tcl_GetString(v); continue; }
        if (strcmp(a, "-type")  == 0) { o->type  = Tcl_GetString(v); continue; }
        if (strcmp(a, "-headers") == 0) {
            Tcl_Size n;
            if (Tcl_DictObjSize(interp, v, &n) != TCL_OK) {
                return http_error(interp, "badvalue", "-headers takes a dict");
            }
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

static int http_do(Tcl_Interp *interp, const char *verb, const char *url,
                   const unsigned char *body, Tcl_Size bodylen, HttpOpts *o) {
    HttpReq r;
    memset(&r, 0, sizeof r);

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
    }

    r.session = WinHttpOpen(r.wagent, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                            WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (r.session == NULL) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "oserror", "cannot open an http session", e);
    }
    DWORD t = (DWORD)o->timeout;
    WinHttpSetTimeouts(r.session, (int)t, (int)t, (int)t, (int)t);

    r.conn = WinHttpConnect(r.session, r.whost, uc.nPort, 0);
    if (r.conn == NULL) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "notfound", "cannot reach the host", e);
    }

    DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    r.req = WinHttpOpenRequest(r.conn, r.wverb, r.wpath, NULL,
                               WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (r.req == NULL) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        return http_win_error(interp, "oserror", "cannot build the request", e);
    }

    /* The caller's headers, plus a Content-Type when a body was given and no
     * explicit type was. */
    Tcl_Obj *hdrbuf = Tcl_NewObj();
    Tcl_IncrRefCount(hdrbuf);
    if (o->headers != NULL) {
        Tcl_DictSearch s;
        Tcl_Obj *k, *v;
        int done;
        if (Tcl_DictObjFirst(NULL, o->headers, &s, &k, &v, &done) == TCL_OK) {
            for (; !done; Tcl_DictObjNext(&s, &k, &v, &done)) {
                Tcl_AppendObjToObj(hdrbuf, k);
                Tcl_AppendToObj(hdrbuf, ": ", 2);
                Tcl_AppendObjToObj(hdrbuf, v);
                Tcl_AppendToObj(hdrbuf, "\r\n", 2);
            }
            Tcl_DictObjDone(&s);
        }
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
        if (r.whdrs != NULL) {
            WinHttpAddRequestHeaders(r.req, r.whdrs, (DWORD)-1,
                                     WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
        }
    }
    Tcl_DecrRefCount(hdrbuf);

    if (!WinHttpSendRequest(r.req, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            (LPVOID)body, (DWORD)bodylen, (DWORD)bodylen, 0)) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        /* The TLS failures get their own code, because "the certificate was
         * refused" and "the host is down" call for different responses. */
        if (e == ERROR_WINHTTP_SECURE_FAILURE) {
            return http_win_error(interp, "tls", "the secure connection was refused", e);
        }
        if (e == ERROR_WINHTTP_TIMEOUT) {
            return http_win_error(interp, "timeout", "the request timed out", e);
        }
        if (e == ERROR_WINHTTP_NAME_NOT_RESOLVED || e == ERROR_WINHTTP_CANNOT_CONNECT) {
            return http_win_error(interp, "notfound", "cannot reach the host", e);
        }
        return http_win_error(interp, "oserror", "the request failed", e);
    }
    if (!WinHttpReceiveResponse(r.req, NULL)) {
        DWORD e = GetLastError();
        http_cleanup(&r);
        if (e == ERROR_WINHTTP_TIMEOUT) {
            return http_win_error(interp, "timeout", "the response timed out", e);
        }
        return http_win_error(interp, "oserror", "no response", e);
    }

    DWORD status = 0, slen = sizeof status;
    WinHttpQueryHeaders(r.req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX, &status, &slen, WINHTTP_NO_HEADER_INDEX);

    /* Raw headers: asked for its size first, the same discipline as every other
     * sized Win32 query in this codebase. */
    DWORD rawlen = 0;
    WinHttpQueryHeaders(r.req, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX,
                        NULL, &rawlen, WINHTTP_NO_HEADER_INDEX);
    Tcl_Obj *hdict = Tcl_NewDictObj();
    Tcl_Obj *rawobj = Tcl_NewStringObj("", 0);
    if (rawlen > 0) {
        wchar_t *raw = (wchar_t *)malloc(rawlen + sizeof(wchar_t));
        if (raw != NULL) {
            if (WinHttpQueryHeaders(r.req, WINHTTP_QUERY_RAW_HEADERS_CRLF,
                                    WINHTTP_HEADER_NAME_BY_INDEX, raw, &rawlen,
                                    WINHTTP_NO_HEADER_INDEX)) {
                char *u = http_utf8(raw, (int)(rawlen / sizeof(wchar_t)));
                if (u != NULL) {
                    Tcl_SetStringObj(rawobj, u, -1);
                    /* Split on CRLF; the first line is the status line, which is
                     * not a header and is skipped. */
                    const char *p = u;
                    int firstline = 1;
                    while (*p) {
                        const char *nl = strstr(p, "\r\n");
                        size_t len = nl ? (size_t)(nl - p) : strlen(p);
                        if (len > 0 && !firstline) http_put_header(hdict, p, len);
                        firstline = 0;
                        if (nl == NULL) break;
                        p = nl + 2;
                    }
                    free(u);
                }
            }
            free(raw);
        }
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
            return http_win_error(interp, "oserror", "the response could not be read", e);
        }
        if (avail == 0) break;
        if (used + (Tcl_WideInt)avail > o->maxbody) {
            free(buf);
            Tcl_DecrRefCount(hdict); Tcl_DecrRefCount(rawobj);
            http_cleanup(&r);
            /* REFUSED, NOT TRUNCATED. A short body that looks whole is the one
             * answer this codebase never gives. */
            return http_error(interp, "toobig",
                "the response exceeds -maxbody; raise it or stream to a file");
        }
        if (used + (Tcl_WideInt)avail > cap) {
            Tcl_WideInt ncap = cap ? cap * 2 : (Tcl_WideInt)HTTP_READ_CHUNK;
            while (ncap < used + (Tcl_WideInt)avail) ncap *= 2;
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
            return http_win_error(interp, "oserror", "the response could not be read", e);
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
        Tcl_WrongNumArgs(interp, 1, objv, "get|post url ?body? ?-headers dict? "
                                          "?-timeout 30s? ?-agent name? ?-type mime? "
                                          "?-maxbody n?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", 0, &idx) != TCL_OK) {
        return TCL_ERROR;
    }
    const char *url = Tcl_GetString(objv[2]);
    HttpOpts o;
    if (idx == H_GET) {
        if (http_opts(interp, objc, objv, 3, &o) != TCL_OK) return TCL_ERROR;
        return http_do(interp, "GET", url, NULL, 0, &o);
    }
    if (objc < 4) {
        Tcl_WrongNumArgs(interp, 1, objv, "post url body ?options?");
        return TCL_ERROR;
    }
    if (http_opts(interp, objc, objv, 4, &o) != TCL_OK) return TCL_ERROR;
    Tcl_Size blen;
    unsigned char *b = Tcl_GetByteArrayFromObj(objv[3], &blen);
    if (o.type == NULL) o.type = "application/octet-stream";
    return http_do(interp, "POST", url, b, blen, &o);
}

int Machteldhttp_Init(Tcl_Interp *interp) {
    Tcl_CreateObjCommand(interp, "::machteld::http", HttpCmd, NULL, NULL);
    Tcl_PkgProvide(interp, "machteld::http", "0.1");
    return TCL_OK;
}
