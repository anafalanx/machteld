/* Force queue-vs-close ordering with a genuine kernel UDP socket. Exercise
 * cancellation before and after the wait callback hands its event to Tcl. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>
static int fail_registration;
static BOOL WINAPI observe_registration(PHANDLE wait, HANDLE event, WAITORTIMERCALLBACK fn, PVOID context,
                                        ULONG timeout, ULONG flags) {
    if (fail_registration) {SetLastError(ERROR_NOT_ENOUGH_MEMORY); return FALSE;}
    return RegisterWaitForSingleObject(wait, event, fn, context, timeout, flags);
}
#define RegisterWaitForSingleObject observe_registration
#include "../../src/udp.c"

static const char *run(Tcl_Interp *ip, const char *code) {
    if (Tcl_Eval(ip, code) != TCL_OK) {fprintf(stderr, "%s -> %s\n", code, Tcl_GetStringResult(ip)); exit(1);}
    return Tcl_GetStringResult(ip);
}
static void expect(Tcl_Interp *ip, const char *code, const char *wanted) {
    const char *r = run(ip, code);
    if (strcmp(r, wanted)) {fprintf(stderr, "%s -> %s, expected %s\n", code, r, wanted); exit(1);}
}
static Socket *open_rx(Tcl_Interp *ip) {
    const char *cmd = run(ip, "set rx [::machteld::network::udp open 127.0.0.1 0]");
    Tcl_CmdInfo info;
    if (!Tcl_GetCommandInfo(ip, cmd, &info)) exit(2);
    return info.objClientData;
}
static void queued(Socket *s) {
    for (int i = 0; i < 5000; ++i) {
        if (InterlockedCompareExchange(&s->queued, 0, 0)) return;
        Sleep(1);
    }
    fputs("no real WSAEventSelect notification arrived\n", stderr); exit(1);
}
int main(int argc, char **argv) {
    (void)argc;
    Tcl_FindExecutable(argv[0]);
    Tcl_Interp *ip = Tcl_CreateInterp();
    run(ip, "namespace eval ::machteld::network {}; set calls 0; proc cb {s} {incr ::calls; $s receive}");
    Machteldudp_Register(ip);
    run(ip, "set tx [::machteld::network::udp open 127.0.0.1 0]");
    DWORD before = 0, after = 0;
    for (int i = 0; i < 320; ++i) {
        if (i == 64 && !GetProcessHandleCount(GetCurrentProcess(), &before)) return 2;
        Socket *s = open_rx(ip);
        fail_registration = 1;
        expect(ip, "catch {$rx readable cb} why opts; list [dict get $opts -errorcode] [$rx readable]",
               "{MACHTELD UDP oserror 8} {}");
        fail_registration = 0;
        run(ip, "$rx readable cb");
        int mode = i % 4;
        if (mode != 0) {
            run(ip, "$tx send 127.0.0.1 [dict get [$rx local] port] abc");
            queued(s);
        }
        if (mode == 1) {
            run(ip, "$rx readable {}; update");
            expect(ip, "dict get [$rx receive] bytes", "abc");
        } else if (mode == 2) {
            run(ip, "set was $calls; update");
            expect(ip, "expr {$calls - $was}", "1");
        } else if (mode == 3) {
            /* Consume after queuing. The callback must recognize stale readiness. */
            expect(ip, "dict get [$rx receive] bytes", "abc");
            run(ip, "set was $calls; update");
            expect(ip, "expr {$calls - $was}", "0");
            run(ip, "$tx send 127.0.0.1 [dict get [$rx local] port] abc");
            queued(s);
        }
        run(ip, "set was $calls; $rx close; update");
        expect(ip, "expr {$calls - $was}", "0");
    }
    if (!GetProcessHandleCount(GetCurrentProcess(), &after) || after > before + 4) return 1;
    expect(ip, "set calls", "80");
    run(ip, "$tx close"); Tcl_DeleteInterp(ip); Tcl_Finalize();
    printf("320 real sockets, wait allocation failures, queued cancellation, stale readiness and pending close; handles %lu -> %lu\n", before, after);
    return 0;
}
