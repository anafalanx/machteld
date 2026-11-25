#ifndef MACHTELD_HTTP_INTERNAL_H
#define MACHTELD_HTTP_INTERNAL_H
#include "machteld.h"
#include <windows.h>
#include <winhttp.h>

typedef struct {
    Tcl_WideInt timeout;        /* ms */
    Tcl_WideInt maxbody;
    const char *agent;
    Tcl_Obj    *headers;        /* dict, caller's -- borrowed, never freed here */
    const char *type;           /* -type: Content-Type for a body */
    int         has_content_type;
    int         redirect_none;  /* -redirect none: return the first 3xx */
} HttpOpts;

typedef struct {
    HINTERNET session, conn, req;
    wchar_t  *wurl, *whost, *wpath, *wverb, *wagent, *whdrs;
} HttpReq;

int http_error(Tcl_Interp *interp, const char *code, const char *message);
int http_win_error(Tcl_Interp *interp, const char *code, const char *what, DWORD error);
int http_request_error(Tcl_Interp *interp, DWORD error, const char *what);
int http_open(Tcl_Interp *interp, const char *verb, const char *url, HttpOpts *options, DWORD flags, HttpReq *output);
void http_cleanup(HttpReq *request);
/* On success the caller owns one Tcl reference to the header dictionary. */
int http_response_headers(Tcl_Interp *interp, HINTERNET request, Tcl_Obj **headers);
int http_stream(Tcl_Interp *interp, const char *url, HttpOpts *options);
#endif
