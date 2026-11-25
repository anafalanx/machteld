/* Asynchronous, pull-driven WinHTTP GET. Only the Tcl thread opens or closes
 * handles, requests another read, or uses Tcl. Windows may deliver completions
 * after cancellation, including after the interpreter has already gone away. */
#include "http_internal.h"
#include <stdio.h>
#include <stdlib.h>

#define STREAM_BUFFER 65536
typedef struct Stream Stream;

typedef struct {
    LONG refs;
    LONG completion;
    DWORD count;
    DWORD error;
    SRWLOCK lock;
    Tcl_ThreadId owner;
    Stream *stream;
    int watching, queued;
    unsigned char data[STREAM_BUFFER];
} Transfer;

typedef enum {
    SENDING, RECEIVING, HEADERS_READY, NEXT_READ, QUERYING, READING,
    DATA_READY, FINISHED, FAILED, CANCELLED
} Phase;

struct Stream {
    Tcl_Interp *interp;
    Tcl_Command command;
    Tcl_Obj *callback, *headers, *failure, *options;
    HttpReq request;
    Transfer *transfer;
    Phase phase;
    Tcl_WideInt bytes, limit;
};

typedef struct {
    Tcl_Event event;
    Transfer *transfer;
} ReadyEvent;

static int ready_event(Tcl_Event *event, int flags);

static void transfer_release(Transfer *t) {
    if (InterlockedDecrement(&t->refs) == 0) free(t);
}

/* The lock serializes posting with interpreter teardown. Only the receiving
 * Tcl thread may dereference stream or evaluate the registered command. */
static void wake(Transfer *t) {
    AcquireSRWLockExclusive(&t->lock);
    if (t->stream && t->watching && !t->queued) {
        ReadyEvent *e = (ReadyEvent *)Tcl_Alloc(sizeof *e);
        e->event.proc = ready_event;
        e->transfer = t;
        InterlockedIncrement(&t->refs);
        t->queued = 1;
        Tcl_ThreadQueueEvent(t->owner, &e->event, TCL_QUEUE_TAIL);
        Tcl_ThreadAlert(t->owner);
    }
    ReleaseSRWLockExclusive(&t->lock);
}

static int discard_event(Tcl_Event *event, void *data) {
    if (event->proc != ready_event || ((ReadyEvent *)event)->transfer != data) return 0;
    transfer_release((Transfer *)data);
    return 1;
}

static void CALLBACK completed(HINTERNET request, DWORD_PTR context, DWORD status,
                               void *info, DWORD length) {
    Transfer *t = (Transfer *)context;
    (void)request;
    if (t == NULL) return;
    if (status == WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING) {
        transfer_release(t);
        return;
    }
    /* The consumer may close the stream the moment it sees our completion.
     * Keep this invocation alive through its final notifier call. */
    InterlockedIncrement(&t->refs);
    switch (status) {
    case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
        t->error = ((WINHTTP_ASYNC_RESULT *)info)->dwError;
        break;
    case WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE:
        t->count = *(DWORD *)info;
        break;
    case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
        t->count = length;
        break;
    case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
    case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
        break;
    default:
        transfer_release(t);
        return;
    }
    /* Publish the data only after Windows finished writing the shared fields.
     * Exactly one operation is outstanding for this request. */
    InterlockedExchange(&t->completion, (LONG)status);
    wake(t);
    transfer_release(t);
}

static void remember_failure(Stream *s) {
    s->failure = Tcl_GetObjResult(s->interp);
    Tcl_IncrRefCount(s->failure);
    s->options = Tcl_GetReturnOptions(s->interp, TCL_ERROR);
    Tcl_IncrRefCount(s->options);
    s->phase = FAILED;
    http_cleanup(&s->request);
}

static void failed_operation(Stream *s, DWORD error) {
    http_request_error(s->interp, error, "stream request failed");
    remember_failure(s);
}

static int available(Phase p) {
    return p == HEADERS_READY || p == DATA_READY || p == FINISHED ||
           p == FAILED || p == CANCELLED;
}

/* Advance network protocol completions as far as possible without waiting.
 * HEADERS_READY and DATA_READY stop the pipeline until Tcl takes the event. */
static void advance(Stream *s) {
    Transfer *t = s->transfer;
    while (!available(s->phase)) {
        if (s->phase == NEXT_READ) {
            s->phase = QUERYING;
            if (!WinHttpQueryDataAvailable(s->request.req, NULL)) {
                failed_operation(s, GetLastError());
                return;
            }
        }
        DWORD status = (DWORD)InterlockedExchange(&t->completion, 0);
        if (!status) return;
        if (status == WINHTTP_CALLBACK_STATUS_REQUEST_ERROR) {
            failed_operation(s, t->error);
            return;
        }
        switch (status) {
        case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
            s->phase = RECEIVING;
            if (!WinHttpReceiveResponse(s->request.req, NULL)) failed_operation(s, GetLastError());
            break;
        case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
            if (http_response_headers(s->interp, s->request.req, &s->headers) != TCL_OK) {
                remember_failure(s);
            } else {
                s->phase = HEADERS_READY;
            }
            break;
        case WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE: {
            DWORD count = t->count;
            if (!count) {
                s->phase = FINISHED;
                http_cleanup(&s->request);
                break;
            }
            if (count > STREAM_BUFFER) count = STREAM_BUFFER;
            if (s->bytes > s->limit - (Tcl_WideInt)count) {
                http_error(s->interp, "toobig", "the response exceeds -maxbody");
                remember_failure(s);
                break;
            }
            s->phase = READING;
            if (!WinHttpReadData(s->request.req, t->data, count, NULL)) failed_operation(s, GetLastError());
            break;
        }
        case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
            if (t->count) {
                s->bytes += t->count;
                s->phase = DATA_READY;
            } else {
                s->phase = FINISHED;
                http_cleanup(&s->request);
            }
            break;
        }
    }
}

static void destroy_stream(void *clientData) {
    Stream *s = (Stream *)clientData;
    AcquireSRWLockExclusive(&s->transfer->lock);
    s->transfer->stream = NULL;
    ReleaseSRWLockExclusive(&s->transfer->lock);
    Tcl_DeleteEvents(discard_event, s->transfer);
    if (s->callback) Tcl_DecrRefCount(s->callback);
    if (s->headers) Tcl_DecrRefCount(s->headers);
    if (s->failure) Tcl_DecrRefCount(s->failure);
    if (s->options) Tcl_DecrRefCount(s->options);
    http_cleanup(&s->request);
    transfer_release(s->transfer);
    free(s);
}

static int ready_event(Tcl_Event *event, int flags) {
    if (!(flags & TCL_FILE_EVENTS)) return 0;
    Transfer *t = ((ReadyEvent *)event)->transfer;
    AcquireSRWLockExclusive(&t->lock);
    t->queued = 0;
    Stream *s = t->stream;
    ReleaseSRWLockExclusive(&t->lock);
    if (!s || !s->callback) {
        transfer_release(t);
        return 1;
    }
    Tcl_Interp *interp = s->interp;
    Tcl_InterpState saved = Tcl_SaveInterpState(interp, TCL_OK);
    advance(s);
    if (!available(s->phase)) {
        Tcl_RestoreInterpState(interp, saved);
        transfer_release(t);
        return 1;
    }
    /* The callback can cancel, close, rename its command, register a new
     * callback, or delete the interpreter. Do not touch s after evaluation. */
    Tcl_Obj *script = s->callback;
    s->callback = NULL;
    AcquireSRWLockExclusive(&t->lock);
    t->watching = 0;
    ReleaseSRWLockExclusive(&t->lock);
    Tcl_Obj *name = Tcl_NewObj();
    Tcl_GetCommandFullName(interp, s->command, name);
    Tcl_ListObjAppendElement(NULL, script, name);
    Tcl_Preserve(interp);
    int code = Tcl_EvalObjEx(interp, script, TCL_EVAL_GLOBAL);
    if (code != TCL_OK && !Tcl_InterpDeleted(interp)) Tcl_BackgroundException(interp, code);
    Tcl_DecrRefCount(script);
    Tcl_RestoreInterpState(interp, saved);
    Tcl_Release(interp);
    transfer_release(t);
    return 1;
}

static int next_event(Stream *s) {
    advance(s);
    if (s->phase == FAILED) {
        Tcl_SetObjResult(s->interp, s->failure);
        return Tcl_SetReturnOptions(s->interp, s->options);
    }
    Tcl_Obj *result;
    const char *event;
    switch (s->phase) {
    case HEADERS_READY:
        result = s->headers;
        s->headers = NULL;
        s->phase = NEXT_READ;
        event = "headers";
        break;
    case DATA_READY:
        result = Tcl_NewDictObj();
        Tcl_IncrRefCount(result);
        Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("data", -1),
                       Tcl_NewByteArrayObj(s->transfer->data, s->transfer->count));
        s->phase = NEXT_READ;
        event = "data";
        break;
    default:
        result = Tcl_NewDictObj();
        Tcl_IncrRefCount(result);
        event = s->phase == FINISHED ? "eof" : s->phase == CANCELLED ? "cancelled" : "pending";
    }
    Tcl_DictObjPut(NULL, result, Tcl_NewStringObj("event", -1), Tcl_NewStringObj(event, -1));
    Tcl_SetObjResult(s->interp, result);
    Tcl_DecrRefCount(result);
    return TCL_OK;
}

static int StreamCmd(void *clientData, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Stream *s = (Stream *)clientData;
    static const char *const words[] = { "next", "readable", "cancel", "close", NULL };
    enum { NEXT, READABLE, CANCEL, CLOSE };
    int op;
    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "next|readable|cancel|close ?commandPrefix?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], words, "operation", TCL_EXACT, &op) != TCL_OK) return TCL_ERROR;
    if (objc != (op == READABLE ? 3 : 2)) {
        Tcl_WrongNumArgs(interp, 2, objv, op == READABLE ? "commandPrefix" : "");
        return TCL_ERROR;
    }
    if (op == NEXT) return next_event(s);
    if (op == CLOSE) {
        Tcl_DeleteCommandFromToken(interp, s->command);
        return TCL_OK;
    }
    if (op == CANCEL) {
        if (s->phase != FINISHED && s->phase != FAILED && s->phase != CANCELLED) {
            s->phase = CANCELLED;
            http_cleanup(&s->request);
            wake(s->transfer);
        }
        return TCL_OK;
    }
    Tcl_Size length;
    if (Tcl_ListObjLength(interp, objv[2], &length) != TCL_OK) return TCL_ERROR;
    if (s->callback) Tcl_DecrRefCount(s->callback);
    s->callback = NULL;
    if (length) {
        s->callback = Tcl_DuplicateObj(objv[2]);
        Tcl_IncrRefCount(s->callback);
    }
    AcquireSRWLockExclusive(&s->transfer->lock);
    s->transfer->watching = length > 0;
    ReleaseSRWLockExclusive(&s->transfer->lock);
    if (length) wake(s->transfer);
    return TCL_OK;
}

int http_stream(Tcl_Interp *interp, const char *url, HttpOpts *options) {
    static LONG64 serial;
    Stream *s = calloc(1, sizeof *s);
    Transfer *t = calloc(1, sizeof *t);
    if (!s || !t) {
        free(s); free(t);
        return http_error(interp, "oserror", "out of memory opening a response stream");
    }
    t->refs = 1;
    t->owner = Tcl_GetCurrentThread();
    t->stream = s;
    s->transfer = t;
    s->interp = interp;
    s->limit = options->maxbody;
    s->phase = SENDING;
    if (http_open(interp, "GET", url, options, WINHTTP_FLAG_ASYNC, &s->request) != TCL_OK) {
        destroy_stream(s);
        return TCL_ERROR;
    }
    DWORD_PTR context = (DWORD_PTR)t;
    DWORD mask = WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS | WINHTTP_CALLBACK_FLAG_HANDLES;
    if (!WinHttpSetOption(s->request.req, WINHTTP_OPTION_CONTEXT_VALUE, &context, sizeof context) ||
        WinHttpSetStatusCallback(s->request.req, completed, mask, 0) == WINHTTP_INVALID_STATUS_CALLBACK) {
        DWORD error = GetLastError();
        destroy_stream(s);
        return http_win_error(interp, "oserror", "cannot register stream notifications", error);
    }
    /* The request handle owns the native block until HANDLE_CLOSING, its
     * final callback. It owns no Tcl object or interpreter pointer. */
    InterlockedIncrement(&t->refs);
    if (!WinHttpSendRequest(s->request.req, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, context)) {
        DWORD error = GetLastError();
        destroy_stream(s);
        return http_request_error(interp, error, "cannot start response stream");
    }
    char name[80];
    do {
        snprintf(name, sizeof name, "::machteld::httpStream%lld", (long long)InterlockedIncrement64(&serial));
    } while (Tcl_FindCommand(interp, name, NULL, TCL_GLOBAL_ONLY));
    s->command = Tcl_CreateObjCommand(interp, name, StreamCmd, s, destroy_stream);
    if (!s->command) {
        destroy_stream(s);
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, Tcl_NewStringObj(name, -1));
    return TCL_OK;
}
