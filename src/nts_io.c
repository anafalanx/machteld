/* Cancellable, deadline-bounded DNS, TCP and datagram transport. Each socket
 * has one owner; no process-global resolver, socket or event state. */
#include "nts_client.h"
#include <wchar.h>

/* Available since Windows 8. MinGW's current headers provide GetAddrInfoExW
 * but omit the two completion functions exported by the same system DLL. */
WINSOCK_API_LINKAGE INT WSAAPI GetAddrInfoExCancel(LPHANDLE);
WINSOCK_API_LINKAGE INT WSAAPI GetAddrInfoExOverlappedResult(LPOVERLAPPED);

DWORD nts_remaining(NtsJob *job) {
    ULONGLONG now = GetTickCount64();
    return job->deadline > now ? (DWORD)(job->deadline - now) : 0;
}
int nts_fail(NtsJob *job, const char *stage, DWORD err) {
    job->stage = stage; job->error = err; return 0;
}
static int ready(NtsJob *job, HANDLE event) {
    HANDLE targets[2] = {job->cancel, event};
    DWORD rc = WaitForMultipleObjects(2, targets, FALSE, nts_remaining(job));
    if (rc == WAIT_OBJECT_0 + 1) return 1;
    return nts_fail(job, rc == WAIT_OBJECT_0 ? "cancelled" : "timeout",
                    rc == WAIT_OBJECT_0 ? ERROR_CANCELLED : rc == WAIT_TIMEOUT ? ERROR_TIMEOUT : GetLastError());
}
static int resolve(NtsJob *job, const wchar_t *host, unsigned short port, int type, ADDRINFOEXW **result) {
    wchar_t service[8];
    swprintf(service, 8, L"%u", port);
    ADDRINFOEXW hint = {0};
    hint.ai_family = AF_UNSPEC; hint.ai_socktype = type;
    hint.ai_protocol = type == SOCK_DGRAM ? IPPROTO_UDP : IPPROTO_TCP;
    hint.ai_flags = AI_NUMERICSERV;
    OVERLAPPED ov = {0};
    ov.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!ov.hEvent) return nts_fail(job, "resolve", GetLastError());
    HANDLE request = NULL;
    int rc = GetAddrInfoExW(host, service, NS_DNS, NULL, &hint, result, NULL, &ov, NULL, &request);
    if (rc == WSA_IO_PENDING) {
        if (!ready(job, ov.hEvent)) {
            GetAddrInfoExCancel(&request);
            WaitForSingleObject(ov.hEvent, INFINITE); /* OVERLAPPED remains owned until completion. */
            CloseHandle(ov.hEvent);
            return 0;
        }
        rc = GetAddrInfoExOverlappedResult(&ov);
    }
    CloseHandle(ov.hEvent);
    return !rc || nts_fail(job, "resolve", (DWORD)rc);
}
void nts_close(NtsSocket *s) {
    if (s->fd != INVALID_SOCKET) closesocket(s->fd);
    if (s->event != WSA_INVALID_EVENT) WSACloseEvent(s->event);
    s->fd = INVALID_SOCKET; s->event = WSA_INVALID_EVENT;
}
static int net_event(NtsSocket *s) {
    if (!ready(s->job, s->event)) return 0;
    WSANETWORKEVENTS events;
    if (WSAEnumNetworkEvents(s->fd, s->event, &events) != 0) return nts_fail(s->job, "socket", WSAGetLastError());
    for (int i = 0; i < FD_MAX_EVENTS; ++i)
        if ((events.lNetworkEvents & (1L << i)) && events.iErrorCode[i]) return nts_fail(s->job, "socket", events.iErrorCode[i]);
    return 1;
}
int nts_connect(NtsJob *job, const wchar_t *host, unsigned short port, int type, NtsSocket *s) {
    s->fd = INVALID_SOCKET; s->event = WSA_INVALID_EVENT; s->job = job;
    ADDRINFOEXW *all = NULL;
    int ok = resolve(job, host, port, type, &all);
    if (ok) {
        ok = 0; nts_fail(job, "connect", WSAEHOSTUNREACH);
        for (ADDRINFOEXW *a = all; a; a = a->ai_next) {
            if (WaitForSingleObject(job->cancel, 0) == WAIT_OBJECT_0 || !nts_remaining(job)) break;
            s->fd = WSASocketW(a->ai_family, type, a->ai_protocol, NULL, 0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
            if (s->fd == INVALID_SOCKET) continue;
            s->event = WSACreateEvent();
            if (s->event != WSA_INVALID_EVENT && WSAEventSelect(s->fd, s->event, FD_CONNECT|FD_READ|FD_WRITE|FD_CLOSE) == 0) {
                if (connect(s->fd, a->ai_addr, (int)a->ai_addrlen) == 0) ok = 1;
                else if (WSAGetLastError() == WSAEWOULDBLOCK && net_event(s)) {
                    int err = 0, n = sizeof err;
                    if (getsockopt(s->fd, SOL_SOCKET, SO_ERROR, (char *)&err, &n) == 0 && !err) ok = 1;
                    else nts_fail(job, "connect", (DWORD)err);
                }
            }
            if (ok) break;
            nts_close(s);
        }
    }
    if (all) FreeAddrInfoExW(all);
    return ok;
}
int nts_send(NtsSocket *s, const void *data, size_t n) {
    const char *p = data;
    while (n) {
        if (!nts_remaining(s->job) || WaitForSingleObject(s->job->cancel, 0) == WAIT_OBJECT_0) return 0;
        int v = send(s->fd, p, (int)n, 0);
        if (v > 0) {p += v; n -= (size_t)v; continue;}
        DWORD err = v ? WSAGetLastError() : WSAECONNRESET;
        if (err != WSAEWOULDBLOCK) return nts_fail(s->job, "send", err);
        if (!net_event(s)) return 0;
    }
    return 1;
}
int nts_recv(NtsSocket *s, void *data, size_t cap) {
    for (;;) {
        if (!nts_remaining(s->job) || WaitForSingleObject(s->job->cancel, 0) == WAIT_OBJECT_0) return -1;
        int v = recv(s->fd, data, (int)cap, 0);
        if (v >= 0) return v;
        int err = WSAGetLastError();
        if (err != WSAEWOULDBLOCK) {nts_fail(s->job, "receive", err); return -1;}
        if (!net_event(s)) return -1;
    }
}
