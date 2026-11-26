/* Windows adapter state, exact source selection, reply statuses and
 * removal between enumeration and query without changing host networking. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <icmpapi.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static DWORD outcome, expected_source;
static int sent, closed, list_mode;
static DWORD WINAPI send_echo(HANDLE h, HANDLE evt, FARPROC apc, void *ctx, IPAddr source, IPAddr dest,
                              void *data, WORD n, PIP_OPTION_INFORMATION opt, void *reply, DWORD size, DWORD timeout) {
    if (h != (HANDLE)1 || evt || apc || ctx || opt || dest != htonl(0xc0000201) ||
        source != expected_source || !data || n == 0 || size < sizeof(ICMP_ECHO_REPLY) + n + 8 || timeout != 91) abort();
    ++sent;
    if (outcome == ERROR_TIMEOUT) {SetLastError(outcome); return 0;}
    ICMP_ECHO_REPLY *r = reply;
    r->Status = outcome; r->RoundTripTime = 7;
    return 1;
}
static HANDLE WINAPI open_echo(void) {return (HANDLE)1;}
static BOOL WINAPI close_echo(HANDLE h) {if (h != (HANDLE)1) abort(); ++closed; return TRUE;}
static ULONG WINAPI get_adapters(ULONG family, ULONG flags, void *reserved, IP_ADAPTER_ADDRESSES *p, ULONG *size) {
    (void)flags; (void)reserved;
    struct two {IP_ADAPTER_ADDRESSES a[2]; IP_ADAPTER_UNICAST_ADDRESS u[2]; struct sockaddr_in ip[2];};
    if (family != AF_INET || *size < sizeof(struct two)) abort();
    struct two *v = (struct two *)p;
    memset(v, 0, sizeof *v);
    v->a[0].Next = &v->a[1];
    for (int i = 0; i < 2; ++i) {
        v->a[i].FirstUnicastAddress = &v->u[i]; v->a[i].OperStatus = IfOperStatusUp;
        v->u[i].DadState = IpDadStatePreferred;
        v->u[i].Address.lpSockaddr = (struct sockaddr *)&v->ip[i];
        v->ip[i].sin_family = AF_INET;
        v->ip[i].sin_addr.s_addr = htonl(0xc0000202 + i);
    }
    return ERROR_SUCCESS;
}
#define GetAdaptersAddresses get_adapters
#define IcmpSendEcho2Ex send_echo
#define IcmpCreateFile open_echo
#define IcmpCloseHandle close_echo
#include "../../src/network.c"

enum { interface_count = 8 };
static int handle_tally, allocations;
static DWORD WINAPI open_wlan(DWORD ver, void *r, DWORD *neg, HANDLE *h) {
    if (ver != 2 || r) abort();
    if (list_mode == 2) return ERROR_SERVICE_NOT_ACTIVE;
    *neg = 2; *h = (HANDLE)2; ++handle_tally; return ERROR_SUCCESS;
}
static DWORD WINAPI close_wlan(HANDLE h, void *r) {
    if (h != (HANDLE)2 || r) abort();
    --handle_tally; return ERROR_SUCCESS;
}
static void WINAPI free_wlan(void *p) {--allocations; free(p);}
static DWORD WINAPI list_wlan(HANDLE h, void *r, WLAN_INTERFACE_INFO_LIST **lst) {
    if (h != (HANDLE)2 || r) abort();
    if (list_mode == 1) return ERROR_ACCESS_DENIED;
    *lst = calloc(1, offsetof(WLAN_INTERFACE_INFO_LIST, InterfaceInfo) +
                     interface_count * sizeof((*lst)->InterfaceInfo[0]));
    if (!*lst) return ERROR_NOT_ENOUGH_MEMORY;
    ++allocations;
    (*lst)->dwNumberOfItems = interface_count;
    for (DWORD i = 0; i < interface_count; ++i) {
        (*lst)->InterfaceInfo[i].InterfaceGuid.Data1 = i + 1;
        (*lst)->InterfaceInfo[i].isState = i + 1 == interface_count ? wlan_interface_state_disconnected : wlan_interface_state_connected;
    }
    return ERROR_SUCCESS;
}
static DWORD WINAPI query_wlan(HANDLE h, const GUID *guid, WLAN_INTF_OPCODE op, void *r, DWORD *size,
                               void **result, WLAN_OPCODE_VALUE_TYPE *kind) {
    if (h != (HANDLE)2 || op != wlan_intf_opcode_current_connection || r || kind || guid->Data1 == interface_count) abort();
    if (guid->Data1 == 2) return ERROR_ACCESS_DENIED;
    if (guid->Data1 == 3) return ERROR_INVALID_STATE;
    if (guid->Data1 == 4) return ERROR_NOT_FOUND;
    WLAN_CONNECTION_ATTRIBUTES *v = calloc(1, sizeof *v);
    if (!v) return ERROR_NOT_ENOUGH_MEMORY;
    ++allocations;
    v->isState = guid->Data1 == 5 ? wlan_interface_state_disconnected : wlan_interface_state_connected;
    v->wlanAssociationAttributes.wlanSignalQuality = 86;
    v->wlanAssociationAttributes.dot11Ssid.uSSIDLength = guid->Data1 == 6 ? 33 : 3;
    memcpy(v->wlanAssociationAttributes.dot11Ssid.ucSSID, "a\0b", 3);
    v->wlanAssociationAttributes.ulRxRate = 780000;
    v->wlanAssociationAttributes.ulTxRate = 560000;
    *result = v; *size = guid->Data1 == 7 ? 1 : sizeof *v; return ERROR_SUCCESS;
}
static BOOL CALLBACK skip_init(PINIT_ONCE once, void *p, void **ctx) {(void)once; (void)p; (void)ctx; return TRUE;}
static void expect(Tcl_Interp *ip, const char *code, const char *want) {
    if (Tcl_Eval(ip, code) != TCL_OK || strcmp(Tcl_GetStringResult(ip), want)) {
        fprintf(stderr, "%s -> '%s', expected '%s'\n", code, Tcl_GetStringResult(ip), want); exit(1);
    }
}
int main(int argc, char **argv) {
    (void)argc;
    Tcl_FindExecutable(argv[0]);
    Tcl_Interp *ip = Tcl_CreateInterp();
    if (Machteldnetwork_Init(ip) != TCL_OK) return 2;
    InitOnceExecuteOnce(&wlan_once, skip_init, NULL, NULL);
    wlan.open.call = open_wlan; wlan.close.call = close_wlan; wlan.free.call = free_wlan;
    wlan.list.call = list_wlan; wlan.query.call = query_wlan;
    for (int repeat = 0; repeat < 40; ++repeat) {
        list_mode = 0;
        expect(ip, "set a [dict get [::machteld::network::wifi] adapters]; lmap r $a {dict get $r details}",
               "ok restricted disconnected unavailable disconnected unavailable unavailable disconnected");
        expect(ip, "set r [lindex $a 0]; list [binary encode hex [dict get $r ssid]] [dict get $r quality] [dict get $r rxkbps] [dict get $r txkbps]", "610062 86 780000 560000");
        expect(ip, "llength [lsort -unique [lmap r $a {dict get $r guid}]]", "8");
        list_mode = 1; expect(ip, "dict get [::machteld::network::wifi] status", "restricted");
        list_mode = 2; expect(ip, "dict get [::machteld::network::wifi] winerror", "1062");
        expected_source = htonl(0xc0000202); outcome = IP_SUCCESS;
        expect(ip, "dict get [::machteld::network::ping 192.0.2.2 192.0.2.1 91] rttms", "7");
        expected_source = htonl(0xc0000203); outcome = IP_REQ_TIMED_OUT;
        expect(ip, "dict get [::machteld::network::ping 192.0.2.3 192.0.2.1 91] status", "timeout");
        outcome = ERROR_TIMEOUT;
        expect(ip, "dict get [::machteld::network::ping 192.0.2.3 192.0.2.1 91] status", "timeout");
        outcome = IP_DEST_NET_UNREACHABLE;
        expect(ip, "dict get [::machteld::network::ping 192.0.2.3 192.0.2.1 91] status", "error");
        expect(ip, "dict get [::machteld::network::ping 192.0.2.9 192.0.2.1 91] winerror", "1168");
    }
    Tcl_DeleteInterp(ip); Tcl_Finalize();
    if (sent != 160 || closed != sent || allocations || handle_tally) return 1;
    puts("40 iterations, 160 source-selected echoes, 8 adapter states, no outstanding allocations or handles");
    return 0;
}
