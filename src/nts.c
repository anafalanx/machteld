/* One RFC 8915 sample per request. A native worker owns transport and
 * secrets. Tcl receives only authenticated timing or a terminal error. */
#undef USE_TCL_STUBS
#include "nts_client.h"
#include "nts_ef.h"
#include "machteld.h"
#include "wintext.h"
#include <bcrypt.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <process.h>

static const char *const state_names[] = {"pending","ok","error","timeout","cancelled"};
static LONG job_state(NtsJob *j) {
    if (!nts_remaining(j) && InterlockedCompareExchange(&j->state, NTS_TIMEOUT, NTS_PENDING) == NTS_PENDING) {
        SetEvent(j->cancel); SetEvent(j->completed);
    }
    return InterlockedCompareExchange(&j->state, 0, 0);
}
static void cancel_job(NtsJob *j) {
    if (InterlockedCompareExchange(&j->state, NTS_CANCELLED, NTS_PENDING) == NTS_PENDING) {
        SetEvent(j->cancel); SetEvent(j->completed);
    }
}
static void release(NtsJob *j) {
    if (InterlockedDecrement(&j->refs)) return;
    if (j->completed) CloseHandle(j->completed);
    if (j->cancel) CloseHandle(j->cancel);
    free(j->trust);
    free(j);
}
static void delete_job(void *d) {NtsJob *j = d; cancel_job(j); release(j);}
static uint32_t be32(const unsigned char *p) {
    return ((uint32_t)p[0]<<24) | ((uint32_t)p[1]<<16) | ((uint32_t)p[2]<<8) | p[3];
}
static void put32(unsigned char *p, uint32_t x) {
    for (int i = 3; i >= 0; --i) {p[i] = (unsigned char)x; x >>= 8;}
}
static int64_t now_ms(void) {
    FILETIME ft; GetSystemTimePreciseAsFileTime(&ft);
    ULARGE_INTEGER v = {.LowPart = ft.dwLowDateTime, .HighPart = ft.dwHighDateTime};
    return (int64_t)(v.QuadPart / 10000) - INT64_C(11644473600000);
}
/* Select the NTP era nearest the local date. Reduces correctly over the
 * 2036 rollover; the normal NTP assumption is within 68 years of the peer. */
static int64_t unfold(const unsigned char *p, int64_t reference) {
    int64_t epoch = reference / 1000 + INT64_C(2208988800);
    int64_t delta = (int64_t)be32(p) - (uint32_t)epoch;
    if (delta > INT32_MAX) delta -= INT64_C(4294967296);
    if (delta < INT32_MIN) delta += INT64_C(4294967296);
    return (epoch + delta - INT64_C(2208988800)) * 1000 + (int64_t)(((uint64_t)be32(p+4) * 1000) >> 32);
}
static int sample(NtsJob *j, NtsKeys *keys, NtsSocket *udp) {
    unsigned char h[48] = {0}, uid[32], nonce[16], query[4096], reply[8192];
    unsigned char cookies[NTSKE_MAX_COOKIES][NTSKE_MAX_COOKIE_LEN];
    size_t lengths[NTSKE_MAX_COOKIES], count = 0, query_len = 0;
    h[0] = 0x23;
    int64_t local = now_ms();
    put32(h+40, (uint32_t)(local / 1000 + INT64_C(2208988800)));
    put32(h+44, (uint32_t)(((uint64_t)(local % 1000) << 32) / 1000));
    if (BCryptGenRandom(NULL, uid, sizeof uid, BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0 ||
        BCryptGenRandom(NULL, nonce, sizeof nonce, BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0)
        return nts_fail(j, "random", ERROR_GEN_FAILURE);
    int ok = 0;
    if (NtsEf_BuildRequest(h, uid, nonce, keys->ke.cookies[0], keys->ke.cookie_len[0], 0, keys->c2s,
                           query, sizeof query, &query_len)) {nts_fail(j, "NTS request", ERROR_INVALID_DATA); goto done;}
    LARGE_INTEGER freq, start, stop;
    QueryPerformanceFrequency(&freq); QueryPerformanceCounter(&start);
    if (!nts_send(udp, query, query_len)) goto done;
    int n = nts_recv(udp, reply, sizeof reply);
    QueryPerformanceCounter(&stop);
    if (n < 0) goto done;
    if (NtsEf_ParseResponse(reply, (size_t)n, uid, keys->s2c, cookies, lengths, &count)) {
        nts_fail(j, "NTS authentication", ERROR_INVALID_DATA); goto done;
    }
    if ((reply[0] & 0x3f) != 0x24 || (reply[0] >> 6) == 3 || reply[1] == 0 || reply[1] > 15 ||
        memcmp(reply+24, h+40, 8) || (!be32(reply+32) && !be32(reply+36)) ||
        (!be32(reply+40) && !be32(reply+44))) {nts_fail(j, "NTP header", ERROR_INVALID_DATA); goto done;}
    int64_t t2 = unfold(reply+32, local), t3 = unfold(reply+40, local);
    if (t3 < t2) {nts_fail(j, "NTP timestamps", ERROR_INVALID_DATA); goto done;}
    int64_t rtt = ((stop.QuadPart-start.QuadPart)*1000 + freq.QuadPart/2)/freq.QuadPart;
    int64_t travel = rtt - (t3-t2);
    j->rttms = (DWORD)rtt; j->unixms = t3 + (travel > 0 ? travel/2 : 0); j->stratum = reply[1];
    ok = 1;
done:
    SecureZeroMemory(cookies, sizeof cookies); SecureZeroMemory(query, sizeof query);
    SecureZeroMemory(uid, sizeof uid); SecureZeroMemory(nonce, sizeof nonce);
    return ok;
}
static unsigned __stdcall execute(void *arg) {
    NtsJob *j = arg;
    NtsKeys keys = {0};
    WSADATA wsa;
    int code = WSAStartup(MAKEWORD(2,2), &wsa), ok = 0;
    if (code) nts_fail(j, "Winsock", code);
    else {
        NtsSocket sock;
        if (nts_connect(j, j->host, j->port, SOCK_STREAM, &sock)) {
            int ke_ok = nts_ke_exchange(j, &sock, &keys);
            wchar_t peer[256] = {0};
            if (ke_ok && !keys.ke.ntp_host[0]) {
                struct sockaddr_storage addr; int len = sizeof addr;
                if (getpeername(sock.fd, (struct sockaddr *)&addr, &len) != 0 ||
                    GetNameInfoW((struct sockaddr *)&addr,len,peer,256,NULL,0,NI_NUMERICHOST) != 0)
                    ke_ok = nts_fail(j, "NTS-KE peer address", WSAGetLastError());
            }
            nts_close(&sock);
            if (ke_ok) {
                wchar_t *override = keys.ke.ntp_host[0] ? mt_utf8_to_wide(keys.ke.ntp_host) : NULL;
                const wchar_t *host = override ? override : peer;
                if (keys.ke.ntp_host[0] && !override) nts_fail(j, "NTP hostname", ERROR_INVALID_DATA);
                else if (nts_connect(j, host, keys.ke.ntp_port ? keys.ke.ntp_port : 123, SOCK_DGRAM, &sock)) {
                    ok = sample(j, &keys, &sock); nts_close(&sock);
                }
                free(override);
            }
        }
        WSACleanup();
    }
    SecureZeroMemory(&keys, sizeof keys);
    LONG end = nts_remaining(j) ? (ok ? NTS_OK : NTS_ERROR) : NTS_TIMEOUT;
    InterlockedCompareExchange(&j->state, end, NTS_PENDING);
    SetEvent(j->completed);
    release(j);
    return 0;
}

static int failed(Tcl_Interp *ip, const char *code, const char *msg) {
    Tcl_SetErrorCode(ip, "MACHTELD", "NTS", code, NULL);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(msg, -1)); return TCL_ERROR;
}
static int result(Tcl_Interp *ip, NtsJob *j, int wait) {
    if (wait && job_state(j) == NTS_PENDING) WaitForSingleObject(j->completed, nts_remaining(j));
    switch (job_state(j)) {
    case NTS_OK: {
        Tcl_Obj *d = Tcl_NewDictObj();
        Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("unixms",-1), Tcl_NewWideIntObj(j->unixms));
        Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("rttms",-1), Tcl_NewWideIntObj(j->rttms));
        Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("stratum",-1), Tcl_NewIntObj(j->stratum));
        Tcl_SetObjResult(ip,d); return TCL_OK;
    }
    case NTS_ERROR: {
        char number[16]; snprintf(number, sizeof number, "%lu", (unsigned long)j->error);
        Tcl_SetErrorCode(ip, "MACHTELD", "NTS", "failed", j->stage, number, NULL);
        Tcl_SetObjResult(ip, Tcl_ObjPrintf("%s failed (code %s)", j->stage, number)); return TCL_ERROR;
    }
    case NTS_TIMEOUT: return failed(ip, "timeout", "NTS request expired");
    case NTS_CANCELLED: return failed(ip, "cancelled", "NTS request was cancelled");
    default: return failed(ip, "pending", "NTS request is still running");
    }
}
static int job_cmd(void *data, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    NtsJob *j = data; int op;
    static const char *const subs[] = {"status","result","wait","cancel","close",NULL};
    if (objc != 2) {Tcl_WrongNumArgs(ip,1,objv,"status|result|wait|cancel|close"); return TCL_ERROR;}
    if (Tcl_GetIndexFromObj(ip,objv[1],subs,"operation",TCL_EXACT,&op) != TCL_OK) return TCL_ERROR;
    if (op == 0) Tcl_SetObjResult(ip, Tcl_NewStringObj(state_names[job_state(j)],-1));
    if (op == 1 || op == 2) return result(ip,j,op == 2);
    if (op == 3) cancel_job(j);
    if (op == 4) Tcl_DeleteCommandFromToken(ip, Tcl_GetCommandFromObj(ip,objv[0]));
    return TCL_OK;
}
static int nts_cmd(void *unused, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
    (void)unused;
    int op;
    static const char *const ops[] = {"sample","start",NULL};
    if (objc < 3 || (objc-3)%2) {
        Tcl_WrongNumArgs(ip,1,objv,"sample|start hostname ?-port port? ?-timeout milliseconds? ?-trustroot derBytes?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(ip,objv[1],ops,"operation",TCL_EXACT,&op) != TCL_OK) return TCL_ERROR;
    Tcl_Size chars;
    const char *host = Tcl_GetStringFromObj(objv[2], &chars);
    if (chars < 1 || chars > 253 || strspn(host,"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-") != (size_t)chars)
        return failed(ip,"badvalue","expected an ASCII DNS name or IP literal");
    int port = 4460, timeout = 5000;
    unsigned char *root = NULL; Tcl_Size n = 0;
    static const char *const opt[] = {"-port","-timeout","-trustroot",NULL};
    for (int i = 3; i < objc; i += 2) {
        int k; if (Tcl_GetIndexFromObj(ip,objv[i],opt,"option",TCL_EXACT,&k) != TCL_OK) return TCL_ERROR;
        if (k < 2) {
            int *dest = k == 0 ? &port : &timeout;
            if (Tcl_GetIntFromObj(ip,objv[i+1],dest) != TCL_OK) return TCL_ERROR;
            if (*dest < 1 || *dest > (k == 0 ? 65535 : 120000)) return failed(ip,"badvalue","port or timeout is out of range");
        } else {
            root = Tcl_GetBytesFromObj(ip,objv[i+1],&n);
            if (!root || n < 1 || n > 65536) return failed(ip,"badvalue","expected one DER trust root of at most 64 KiB");
        }
    }
    NtsJob *j = calloc(1,sizeof *j);
    if (!j) return failed(ip,"oserror","cannot allocate NTS request");
    j->refs = 1; j->port = (unsigned short)port; j->deadline = GetTickCount64() + timeout;
    for (Tcl_Size i = 0; i < chars; ++i) j->host[i] = (unsigned char)host[i];
    if (root) {
        j->trust = malloc((size_t)n);
        if (!j->trust) {release(j); return failed(ip,"oserror","cannot allocate NTS trust root");}
        memcpy(j->trust,root,(size_t)n); j->trust_len = (DWORD)n;
    }
    j->completed = CreateEventW(NULL,TRUE,FALSE,NULL); j->cancel = CreateEventW(NULL,TRUE,FALSE,NULL);
    if (!j->completed || !j->cancel) {release(j); return failed(ip,"oserror","cannot create NTS request events");}
    j->refs = 2;
    HANDLE worker = (HANDLE)_beginthreadex(NULL,0,execute,j,0,NULL);
    if (!worker) {j->refs=1; release(j); return failed(ip,"oserror","cannot start NTS request");}
    CloseHandle(worker);
    if (op == 0) {int rc = result(ip,j,1); cancel_job(j); release(j); return rc;}
    static Tcl_ThreadDataKey ids;
    unsigned long long *serial = Tcl_GetThreadData(&ids,sizeof *serial);
    char name[80];
    do {snprintf(name,sizeof name,"::machteld::network::nts%llu",++*serial);}
    while (Tcl_FindCommand(ip,name,NULL,TCL_GLOBAL_ONLY));
    Tcl_CreateObjCommand(ip,name,job_cmd,j,delete_job);
    Tcl_SetObjResult(ip,Tcl_NewStringObj(name,-1)); return TCL_OK;
}
void Machteldnts_Register(Tcl_Interp *ip) {Tcl_CreateObjCommand(ip,"::machteld::network::nts",nts_cmd,NULL,NULL);}
