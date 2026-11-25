/* Adapted from Airwave's src/monitor.c (SHA-256
 * 69502888a15bbc56f54676c93f7bace205b328c7e0db11b16979e2c270bcc1fe).
 * Copyright (c) 2026 Airwave contributors, MIT. See licenses/Airwave-MIT.txt.
 * WLAN is an optional Windows feature. Failure to load its system DLL must
 * never prevent host startup, UDP or loopback diagnostics. */
#undef USE_TCL_STUBS
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <wlanapi.h>
#include <iphlpapi.h>
#include <icmpapi.h>
#include <stdlib.h>
#include "machteld.h"
#include "wintext.h"

static struct {
    union { FARPROC proc; typeof(&WlanOpenHandle) call; } open;
    union { FARPROC proc; typeof(&WlanEnumInterfaces) call; } list;
    union { FARPROC proc; typeof(&WlanQueryInterface) call; } query;
    union { FARPROC proc; typeof(&WlanFreeMemory) call; } free;
    union { FARPROC proc; typeof(&WlanCloseHandle) call; } close;
    DWORD error;
} wlan;
static INIT_ONCE wlan_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK init_wlan(PINIT_ONCE once, void *unused, void **context) {
    (void)once; (void)unused; (void)context;
    HMODULE m = LoadLibraryExW(L"wlanapi.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!m) {wlan.error = GetLastError(); return TRUE;}
    wlan.open.proc = GetProcAddress(m, "WlanOpenHandle");
    wlan.list.proc = GetProcAddress(m, "WlanEnumInterfaces");
    wlan.query.proc = GetProcAddress(m, "WlanQueryInterface");
    wlan.free.proc = GetProcAddress(m, "WlanFreeMemory");
    wlan.close.proc = GetProcAddress(m, "WlanCloseHandle");
    if (!wlan.open.proc || !wlan.list.proc || !wlan.query.proc || !wlan.free.proc || !wlan.close.proc) {
        wlan.error = ERROR_PROC_NOT_FOUND;
        FreeLibrary(m);
    }
    return TRUE;
}

static void field(Tcl_Obj *d, const char *k, Tcl_Obj *v) {
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj(k, -1), v);
}
static void word(Tcl_Obj *d, const char *k, const char *v) {field(d, k, Tcl_NewStringObj(v, -1));}
static void number(Tcl_Obj *d, const char *k, DWORD v) {field(d, k, Tcl_NewWideIntObj(v));}
static int invalid(Tcl_Interp *interp, const char *why) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(why, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "NETWORK", "badvalue", NULL);
    return TCL_ERROR;
}

/* Size can change between calls as interfaces arrive and disappear. */
static DWORD adapters(IP_ADAPTER_ADDRESSES **result) {
    *result = NULL;
    ULONG bytes = 15000;
    ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    for (int i = 0; i < 5; ++i) {
        IP_ADAPTER_ADDRESSES *p = malloc(bytes);
        if (!p) return ERROR_NOT_ENOUGH_MEMORY;
        DWORD rc = GetAdaptersAddresses(AF_INET, flags, NULL, p, &bytes);
        if (rc == NO_ERROR) {*result = p; return NO_ERROR;}
        free(p);
        if (rc != ERROR_BUFFER_OVERFLOW) return rc;
    }
    return ERROR_BUFFER_OVERFLOW;
}

static int preferred(IP_ADAPTER_UNICAST_ADDRESS *u) {
    return u->Address.lpSockaddr && u->Address.lpSockaddr->sa_family == AF_INET &&
           u->DadState == IpDadStatePreferred;
}

static void ip_fields(Tcl_Obj *row, const GUID *guid, IP_ADAPTER_ADDRESSES *all) {
    NET_LUID luid;
    Tcl_Obj *ips = Tcl_NewListObj(0, NULL);
    if (ConvertInterfaceGuidToLuid(guid, &luid) == NO_ERROR) {
        for (IP_ADAPTER_ADDRESSES *a = all; a; a = a->Next) {
            if (a->Luid.Value != luid.Value) continue;
            char *friendly = a->FriendlyName ? mt_wide_to_utf8(a->FriendlyName, -1) : NULL;
            if (friendly) {word(row, "name", friendly); free(friendly);}
            for (IP_ADAPTER_UNICAST_ADDRESS *u = a->FirstUnicastAddress; u; u = u->Next) {
                if (!preferred(u)) continue;
                char text[INET_ADDRSTRLEN];
                const IN_ADDR *ip = &((struct sockaddr_in *)u->Address.lpSockaddr)->sin_addr;
                if (inet_ntop(AF_INET, ip, text, sizeof text))
                    Tcl_ListObjAppendElement(NULL, ips, Tcl_NewStringObj(text, -1));
            }
            break;
        }
    }
    field(row, "ipv4", ips);
}

static const char *link_state(WLAN_INTERFACE_STATE state) {
    switch (state) {
    case wlan_interface_state_connected: return "connected";
    case wlan_interface_state_disconnected: return "disconnected";
    case wlan_interface_state_disconnecting: return "disconnecting";
    case wlan_interface_state_associating: return "associating";
    case wlan_interface_state_discovering: return "discovering";
    case wlan_interface_state_authenticating: return "authenticating";
    case wlan_interface_state_ad_hoc_network_formed: return "adhoc";
    default: return "unavailable";
    }
}

static Tcl_Obj *wifi_row(HANDLE handle, const WLAN_INTERFACE_INFO *info, IP_ADAPTER_ADDRESSES *all) {
    Tcl_Obj *row = Tcl_NewDictObj();
    wchar_t id[39];
    StringFromGUID2(&info->InterfaceGuid, id, 39);
    char *guid = mt_wide_to_utf8(id, -1);
    char *desc = mt_wide_to_utf8(info->strInterfaceDescription, -1);
    word(row, "guid", guid ? guid : ""); free(guid);
    word(row, "description", desc ? desc : ""); free(desc);
    ip_fields(row, &info->InterfaceGuid, all);
    WLAN_INTERFACE_STATE state = info->isState;
    const char *details = "disconnected";
    DWORD code = ERROR_SUCCESS;
    if (state == wlan_interface_state_connected || state == wlan_interface_state_ad_hoc_network_formed) {
        DWORD bytes = 0;
        WLAN_CONNECTION_ATTRIBUTES *connection = NULL;
        code = wlan.query.call(handle, &info->InterfaceGuid, wlan_intf_opcode_current_connection, NULL,
                               &bytes, (void **)&connection, NULL);
        if (code == ERROR_SUCCESS && (!connection || bytes < sizeof *connection)) code = ERROR_INVALID_DATA;
        if (code == ERROR_SUCCESS) {
            state = connection->isState;
            WLAN_ASSOCIATION_ATTRIBUTES *a = &connection->wlanAssociationAttributes;
            if (state == wlan_interface_state_connected || state == wlan_interface_state_ad_hoc_network_formed) {
                if (a->dot11Ssid.uSSIDLength > sizeof a->dot11Ssid.ucSSID || a->wlanSignalQuality > 100) {
                    code = ERROR_INVALID_DATA;
                } else {
                    details = "ok";
                    field(row, "ssid", Tcl_NewByteArrayObj(a->dot11Ssid.ucSSID, a->dot11Ssid.uSSIDLength));
                    number(row, "quality", a->wlanSignalQuality);
                    number(row, "rxkbps", a->ulRxRate);
                    number(row, "txkbps", a->ulTxRate);
                }
            }
        }
        if (code == ERROR_INVALID_STATE) state = wlan_interface_state_disconnected;
        else if (code == ERROR_ACCESS_DENIED) details = "restricted";
        else if (code != ERROR_SUCCESS) details = "unavailable";
        if (connection) wlan.free.call(connection);
    }
    word(row, "state", link_state(state));
    word(row, "details", details);
    number(row, "winerror", code);
    return row;
}

static int wifi_cmd(void *unused, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)unused;
    if (objc != 1) {Tcl_WrongNumArgs(interp, 1, objv, NULL); return TCL_ERROR;}
    InitOnceExecuteOnce(&wlan_once, init_wlan, NULL, NULL);
    DWORD ver, code = wlan.error, ip_error = 0;
    HANDLE handle = NULL;
    WLAN_INTERFACE_INFO_LIST *interfaces = NULL;
    if (!code) code = wlan.open.call(2, NULL, &ver, &handle);
    if (!code) code = wlan.list.call(handle, NULL, &interfaces);
    Tcl_Obj *result = Tcl_NewDictObj(), *rows = Tcl_NewListObj(0, NULL);
    if (!code && interfaces) {
        IP_ADAPTER_ADDRESSES *all = NULL;
        ip_error = adapters(&all);
        for (DWORD i = 0; i < interfaces->dwNumberOfItems; ++i)
            Tcl_ListObjAppendElement(NULL, rows, wifi_row(handle, &interfaces->InterfaceInfo[i], all));
        free(all);
    }
    if (interfaces) wlan.free.call(interfaces);
    if (handle) wlan.close.call(handle, NULL);
    word(result, "status", !code ? "ok" : code == ERROR_ACCESS_DENIED ? "restricted" : "unavailable");
    number(result, "winerror", code);
    number(result, "addresserror", ip_error);
    field(result, "adapters", rows);
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
}

static int local_source(IN_ADDR source, DWORD *error) {
    IP_ADAPTER_ADDRESSES *all = NULL;
    *error = adapters(&all);
    int found = 0;
    for (IP_ADAPTER_ADDRESSES *a = all; a && !found; a = a->Next) {
        if (a->OperStatus != IfOperStatusUp) continue;
        for (IP_ADAPTER_UNICAST_ADDRESS *u = a->FirstUnicastAddress; u; u = u->Next) {
            if (preferred(u) && ((struct sockaddr_in *)u->Address.lpSockaddr)->sin_addr.s_addr == source.s_addr) {
                found = 1;
                break;
            }
        }
    }
    free(all);
    if (!found && !*error) *error = ERROR_NOT_FOUND;
    return found;
}

static int ping_cmd(void *unused, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)unused;
    if (objc != 3 && objc != 4) {
        Tcl_WrongNumArgs(interp, 1, objv, "sourceIPv4 destinationIPv4 ?timeoutMs?");
        return TCL_ERROR;
    }
    IN_ADDR src, dst;
    if (inet_pton(AF_INET, Tcl_GetString(objv[1]), &src) != 1 || !src.s_addr ||
        inet_pton(AF_INET, Tcl_GetString(objv[2]), &dst) != 1 || !dst.s_addr)
        return invalid(interp, "source and destination must be explicit nonzero IPv4 addresses");
    int timeout = 1000;
    if (objc == 4 && Tcl_GetIntFromObj(interp, objv[3], &timeout) != TCL_OK) return TCL_ERROR;
    if (timeout < 1 || timeout > 60000) return invalid(interp, "timeout must be 1 through 60000 milliseconds");
    DWORD code;
    Tcl_Obj *result = Tcl_NewDictObj();
    if (local_source(src, &code)) {
        HANDLE icmp = IcmpCreateFile();
        if (icmp == INVALID_HANDLE_VALUE) code = GetLastError();
        else {
            char data[] = "Machteld";
            union {ICMP_ECHO_REPLY reply; unsigned char space[256];} buffer = {0};
            DWORD count = IcmpSendEcho2Ex(icmp, NULL, NULL, NULL, src.s_addr, dst.s_addr,
                                          data, sizeof data, NULL, &buffer, sizeof buffer, (DWORD)timeout);
            code = count ? buffer.reply.Status : GetLastError();
            if (count && code == IP_SUCCESS) number(result, "rttms", buffer.reply.RoundTripTime);
            IcmpCloseHandle(icmp);
        }
    }
    const char *status = "error";
    if (code == IP_SUCCESS) status = "ok";
    else if (code == IP_REQ_TIMED_OUT || code == WAIT_TIMEOUT || code == ERROR_TIMEOUT) status = "timeout";
    word(result, "status", status);
    number(result, "winerror", code);
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
}

void Machteldudp_Register(Tcl_Interp *interp);

int Machteldnetwork_Init(Tcl_Interp *interp) {
    if (Tcl_EvalEx(interp, "namespace eval ::machteld::network {}", -1, TCL_EVAL_GLOBAL) != TCL_OK) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "::machteld::network::wifi", wifi_cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::machteld::network::ping", ping_cmd, NULL, NULL);
    Machteldudp_Register(interp);
    return Tcl_PkgProvide(interp, "machteld::network", "1.0");
}
