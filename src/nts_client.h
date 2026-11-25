#ifndef MACHTELD_NTS_CLIENT_H
#define MACHTELD_NTS_CLIENT_H
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdint.h>
#include "nts_ke.h"

enum {NTS_PENDING, NTS_OK, NTS_ERROR, NTS_TIMEOUT, NTS_CANCELLED};
typedef struct {
    LONG refs, state;
    HANDLE cancel, completed;
    ULONGLONG deadline;
    wchar_t host[256];
    unsigned short port;
    unsigned char *trust;
    DWORD trust_len;
    const char *stage;
    DWORD error;
    int stratum;
    int64_t unixms;
    DWORD rttms;
} NtsJob;
typedef struct {SOCKET fd; WSAEVENT event; NtsJob *job;} NtsSocket;
typedef struct {NtsKeResponse ke; uint8_t c2s[32], s2c[32];} NtsKeys;

DWORD nts_remaining(NtsJob *);
int nts_fail(NtsJob *, const char *, DWORD);
int nts_connect(NtsJob *, const wchar_t *, unsigned short, int type, NtsSocket *);
int nts_send(NtsSocket *, const void *, size_t);
int nts_recv(NtsSocket *, void *, size_t);
void nts_close(NtsSocket *);
int nts_ke_exchange(NtsJob *, NtsSocket *, NtsKeys *);
#endif
