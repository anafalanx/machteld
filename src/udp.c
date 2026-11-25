/* The numeric sockaddr parsing adapts Lunar src/netutil.c (SHA-256
 * ccaf5a46eb17049b459fb300b0fb3094ee8c9a27ddc3ab835b8c5e83a3936851).
 * Copyright (c) 2026 the Time Actual authors, MIT; see licenses/Lunar-MIT.txt.
 * A socket and its Tcl callback belong to the interpreter thread. A single
 * Windows wait can queue one preallocated event; it never accesses Tcl
 * objects. Unregistration joins the wait before its state is released. */
#undef USE_TCL_STUBS
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include "machteld.h"

typedef struct Socket Socket;
typedef struct {
    Tcl_Event header;
    Socket *socket;
} ReadEvent;

struct Socket {
    Tcl_Interp *interp;
    Tcl_ThreadId owner;
    Tcl_Command command;
    SOCKET fd;
    int family;
    WSAEVENT ready;
    HANDLE wait;
    ReadEvent *event;
    LONG queued;
    Tcl_Obj *prefix;
    unsigned long long generation;
};

static int bad(Tcl_Interp *ip, const char *reason) {
    Tcl_SetObjResult(ip, Tcl_NewStringObj(reason, -1));
    Tcl_SetErrorCode(ip, "MACHTELD", "UDP", "badvalue", NULL);
    return TCL_ERROR;
}
static int sys_error(Tcl_Interp *ip, const char *op, DWORD code) {
    char number[16];
    snprintf(number, sizeof number, "%lu", (unsigned long)code);
    Tcl_SetObjResult(ip, Tcl_ObjPrintf("%s failed (Windows %s)", op, number));
    Tcl_SetErrorCode(ip, "MACHTELD", "UDP", "oserror", number, NULL);
    return TCL_ERROR;
}
static int endpoint(Tcl_Interp *ip, Tcl_Obj *address, Tcl_Obj *port, struct sockaddr_storage *out, int *len) {
    int p;
    if (Tcl_GetIntFromObj(ip, port, &p) != TCL_OK) return TCL_ERROR;
    if (p < 0 || p > 65535) return bad(ip, "port must be 0 through 65535");
    Tcl_Size n;
    const char *literal = Tcl_GetStringFromObj(address, &n);
    if (n < 1 || n >= INET6_ADDRSTRLEN + 12) return bad(ip, "expected a numeric IPv4 or IPv6 address");
    memset(out, 0, sizeof *out);
    struct sockaddr_in *v4 = (struct sockaddr_in *)out;
    if (inet_pton(AF_INET, literal, &v4->sin_addr) == 1) {
        v4->sin_family = AF_INET; v4->sin_port = htons((u_short)p); *len = sizeof *v4;
        return TCL_OK;
    }
    char text[INET6_ADDRSTRLEN + 12];
    memcpy(text, literal, (size_t)n + 1);
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)out;
    char *scope = strchr(text, '%');
    if (scope) {
        *scope++ = 0;
        if (!*scope) return bad(ip, "expected a numeric IPv6 scope identifier");
        uint64_t id = 0;
        for (const char *q = scope; *q; ++q) {
            if (*q < '0' || *q > '9') return bad(ip, "expected a numeric IPv6 scope identifier");
            id = id * 10 + (unsigned)(*q - '0');
            if (id > UINT32_MAX) return bad(ip, "IPv6 scope identifier is out of range");
        }
        v6->sin6_scope_id = (ULONG)id;
    }
    if (inet_pton(AF_INET6, text, &v6->sin6_addr) != 1) return bad(ip, "expected a numeric IPv4 or IPv6 address");
    v6->sin6_family = AF_INET6; v6->sin6_port = htons((u_short)p); *len = sizeof *v6;
    return TCL_OK;
}

static Tcl_Obj *endpoint_dict(const struct sockaddr_storage *a) {
    char text[INET6_ADDRSTRLEN + 12] = "";
    unsigned short port;
    if (a->ss_family == AF_INET6) {
        const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)a;
        inet_ntop(AF_INET6, &v6->sin6_addr, text, INET6_ADDRSTRLEN);
        if (v6->sin6_scope_id) {
            size_t used = strlen(text);
            snprintf(text + used, sizeof text - used, "%%%lu", (unsigned long)v6->sin6_scope_id);
        }
        port = ntohs(v6->sin6_port);
    } else {
        const struct sockaddr_in *v4 = (const struct sockaddr_in *)a;
        inet_ntop(AF_INET, &v4->sin_addr, text, INET_ADDRSTRLEN);
        port = ntohs(v4->sin_port);
    }
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("address", -1), Tcl_NewStringObj(text, -1));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("port", -1), Tcl_NewIntObj(port));
    return d;
}

static int read_event(Tcl_Event *, int);
static int same_event(Tcl_Event *e, void *wanted) {return (void *)e == wanted;}

static void CALLBACK signal_ready(void *arg, BOOLEAN expired) {
    (void)expired;
    Socket *s = arg;
    InterlockedExchange(&s->queued, 1);
    Tcl_ThreadQueueEvent(s->owner, &s->event->header, TCL_QUEUE_TAIL);
    Tcl_ThreadAlert(s->owner);
}
static int arm(Socket *s) {
    s->event = (ReadEvent *)Tcl_Alloc(sizeof *s->event);
    s->event->header.proc = read_event;
    s->event->socket = s;
    s->queued = 0;
    if (!RegisterWaitForSingleObject(&s->wait, s->ready, signal_ready, s, INFINITE, WT_EXECUTEONLYONCE)) {
        DWORD code = GetLastError();
        Tcl_Free(s->event); s->event = NULL; s->wait = NULL;
        return sys_error(s->interp, "register UDP read wait", code);
    }
    return TCL_OK;
}
static void retire_wait(Socket *s, int delivering) {
    if (!s->wait) return;
    UnregisterWaitEx(s->wait, INVALID_HANDLE_VALUE);
    s->wait = NULL;
    if (!delivering) {
        if (s->queued) Tcl_DeleteEvents(same_event, s->event);
        else Tcl_Free(s->event);
    }
    s->event = NULL;
}
static void unsubscribe(Socket *s) {
    ++s->generation;
    retire_wait(s, 0);
    if (s->prefix) {
        WSAEventSelect(s->fd, NULL, 0);
        WSAResetEvent(s->ready);
        Tcl_DecrRefCount(s->prefix); s->prefix = NULL;
    }
}
static void delete_socket(void *data) {
    Socket *s = data;
    unsubscribe(s);
    s->command = NULL;
    closesocket(s->fd);
    WSACloseEvent(s->ready);
    WSACleanup();
    Tcl_EventuallyFree(s, TCL_DYNAMIC);
}
static int read_event(Tcl_Event *event, int flags) {
    if (!(flags & TCL_FILE_EVENTS)) return 0;
    Socket *s = ((ReadEvent *)event)->socket;
    Tcl_Interp *ip = s->interp;
    retire_wait(s, 1);
    Tcl_Preserve(s); Tcl_Preserve(ip);
    Tcl_InterpState state = Tcl_SaveInterpState(ip, TCL_OK);
    unsigned long long generation = s->generation;
    WSANETWORKEVENTS events;
    int rc = TCL_OK;
    if (WSAEnumNetworkEvents(s->fd, s->ready, &events) != 0) {
        rc = sys_error(ip, "inspect UDP read readiness", WSAGetLastError());
    } else if (events.lNetworkEvents & FD_READ) {
        /* A synchronous receive can have consumed the datagram while this
         * event was queued. select is nonblocking and handles empty packets. */
        fd_set fds; FD_ZERO(&fds); FD_SET(s->fd, &fds);
        struct timeval now = {0, 0};
        int ready = select(0, &fds, NULL, NULL, &now);
        if (ready == SOCKET_ERROR) rc = sys_error(ip, "inspect UDP socket", WSAGetLastError());
        else if (ready > 0) {
            Tcl_Obj *cmd = Tcl_DuplicateObj(s->prefix), *name = Tcl_NewObj();
            Tcl_IncrRefCount(cmd);
            Tcl_GetCommandFullName(ip, s->command, name);
            Tcl_ListObjAppendElement(ip, cmd, name);
            rc = Tcl_EvalObjEx(ip, cmd, TCL_EVAL_GLOBAL);
            Tcl_DecrRefCount(cmd);
        }
    }
    if (s->command && s->generation == generation) {
        if (rc == TCL_OK) rc = arm(s);
        if (rc != TCL_OK) unsubscribe(s);
    }
    if (rc != TCL_OK && !Tcl_InterpDeleted(ip)) Tcl_BackgroundException(ip, rc);
    Tcl_RestoreInterpState(ip, state);
    Tcl_Release(ip); Tcl_Release(s);
    return 1;
}
static int set_readable(Socket *s, Tcl_Obj *prefix) {
    Tcl_Size len;
    if (Tcl_ListObjLength(s->interp, prefix, &len) != TCL_OK) return TCL_ERROR;
    unsubscribe(s);
    if (!len) return TCL_OK;
    if (WSAEventSelect(s->fd, s->ready, FD_READ) == SOCKET_ERROR)
        return sys_error(s->interp, "watch UDP socket", WSAGetLastError());
    s->prefix = prefix; Tcl_IncrRefCount(prefix);
    int rc = arm(s);
    if (rc != TCL_OK) unsubscribe(s);
    return rc;
}

static int socket_cmd(void *data, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    Socket *s = data;
    static const char *const ops[] = {"local","send","receive","readable","close",NULL};
    enum {LOCAL,SEND,RECEIVE,READABLE,CLOSE};
    int op;
    if (objc < 2) {Tcl_WrongNumArgs(ip, 1, objv, "local|send|receive|readable|close"); return TCL_ERROR;}
    if (Tcl_GetIndexFromObj(ip, objv[1], ops, "operation", TCL_EXACT, &op) != TCL_OK) return TCL_ERROR;
    struct sockaddr_storage addr;
    int len = sizeof addr;
    if (op == SEND) {
        if (objc != 5) {Tcl_WrongNumArgs(ip, 2, objv, "address port bytes"); return TCL_ERROR;}
        if (endpoint(ip, objv[2], objv[3], &addr, &len) != TCL_OK) return TCL_ERROR;
        if (addr.ss_family != s->family) return bad(ip, "destination address family must match the socket");
        Tcl_Size n;
        Tcl_DString scratch;
        const unsigned char *p = Machteld_ValueBytes(objv[4], &n, &scratch);
        int limit = s->family == AF_INET ? 65507 : 65527;
        if (n > limit) {Tcl_DStringFree(&scratch); return bad(ip, "payload exceeds the UDP datagram limit");}
        int count = sendto(s->fd, (const char *)p, (int)n, 0, (struct sockaddr *)&addr, len);
        int code = count == SOCKET_ERROR ? WSAGetLastError() : 0;
        Tcl_DStringFree(&scratch);
        if (code) return sys_error(ip, "send UDP datagram", (DWORD)code);
        Tcl_SetObjResult(ip, Tcl_NewIntObj(count));
    } else if (op == READABLE) {
        if (objc == 3) return set_readable(s, objv[2]);
        if (objc != 2) {Tcl_WrongNumArgs(ip, 2, objv, "?commandPrefix?"); return TCL_ERROR;}
        if (s->prefix) Tcl_SetObjResult(ip, s->prefix);
    } else {
        if (objc != 2) {Tcl_WrongNumArgs(ip, 2, objv, NULL); return TCL_ERROR;}
        if (op == CLOSE) {Tcl_DeleteCommandFromToken(ip, s->command); return TCL_OK;}
        if (op == LOCAL) {
            if (getsockname(s->fd, (struct sockaddr *)&addr, &len) != 0)
                return sys_error(ip, "get local UDP address", WSAGetLastError());
            Tcl_SetObjResult(ip, endpoint_dict(&addr));
        } else {
            Tcl_Obj *bytes = Tcl_NewObj();
            Tcl_IncrRefCount(bytes);
            unsigned char *buffer = Tcl_SetByteArrayLength(bytes, 65535);
            int n = recvfrom(s->fd, (char *)buffer, 65535, 0, (struct sockaddr *)&addr, &len);
            if (n == SOCKET_ERROR) {
                int code = WSAGetLastError();
                Tcl_DecrRefCount(bytes);
                if (code == WSAEWOULDBLOCK) return TCL_OK;
                return sys_error(ip, "receive UDP datagram", (DWORD)code);
            }
            Tcl_SetByteArrayLength(bytes, n);
            Tcl_Obj *d = endpoint_dict(&addr);
            Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("bytes", -1), bytes);
            Tcl_DecrRefCount(bytes);
            Tcl_SetObjResult(ip, d);
        }
    }
    return TCL_OK;
}

static int open_cmd(void *unused, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void)unused;
    if (objc != 4 || strcmp(Tcl_GetString(objv[1]), "open")) {
        Tcl_WrongNumArgs(ip, 1, objv, "open address port"); return TCL_ERROR;
    }
    struct sockaddr_storage addr;
    int len;
    if (endpoint(ip, objv[2], objv[3], &addr, &len) != TCL_OK) return TCL_ERROR;
    WSADATA wsa;
    int code = WSAStartup(MAKEWORD(2, 2), &wsa);
    if (code) return sys_error(ip, "initialize Winsock", (DWORD)code);
    SOCKET fd = WSASocketW(addr.ss_family, SOCK_DGRAM, IPPROTO_UDP, NULL, 0,
                           WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
    WSAEVENT ready = WSA_INVALID_EVENT;
    if (fd != INVALID_SOCKET) {
        BOOL yes = TRUE;
        u_long nonblocking = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (char *)&yes, sizeof yes) == 0 &&
            (addr.ss_family != AF_INET6 ||
             setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, (char *)&yes, sizeof yes) == 0) &&
            ioctlsocket(fd, FIONBIO, &nonblocking) == 0 &&
            bind(fd, (struct sockaddr *)&addr, len) == 0) ready = WSACreateEvent();
    }
    if (ready == WSA_INVALID_EVENT) {
        code = WSAGetLastError();
        if (fd != INVALID_SOCKET) closesocket(fd);
        WSACleanup();
        return sys_error(ip, "open UDP socket", (DWORD)code);
    }
    Socket *s = (Socket *)Tcl_Alloc(sizeof *s);
    memset(s, 0, sizeof *s);
    s->fd = fd; s->family = addr.ss_family; s->ready = ready; s->owner = Tcl_GetCurrentThread(); s->interp = ip;
    static Tcl_ThreadDataKey ids;
    unsigned long long *serial = Tcl_GetThreadData(&ids, sizeof *serial);
    char name[80];
    do {snprintf(name, sizeof name, "::machteld::network::udp%llu", ++*serial);}
    while (Tcl_FindCommand(ip, name, NULL, TCL_GLOBAL_ONLY));
    s->command = Tcl_CreateObjCommand(ip, name, socket_cmd, s, delete_socket);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(name, -1));
    return TCL_OK;
}

void Machteldudp_Register(Tcl_Interp *ip) {
    Tcl_CreateObjCommand(ip, "::machteld::network::udp", open_cmd, NULL, NULL);
}
