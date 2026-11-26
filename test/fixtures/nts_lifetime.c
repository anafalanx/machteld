/* Check release after cancelling a real pending TLS handshake, closing
 * its command, deleting the owning interpreter, and an autonomous deadline. */
#include "../../src/nts.c"
static void require(int ok, const char *msg) {if (!ok) {fprintf(stderr,"%s\n",msg); exit(1);}}
static int simulated, calls;
static ULONGLONG ticks;
static DWORD requested[2], second_result;
static ULONGLONG WINAPI test_ticks(void) {return simulated ? ticks : GetTickCount64();}
static DWORD WINAPI test_wait(DWORD count, const HANDLE *handles, BOOL all, DWORD timeout) {
    if (!simulated) return WaitForMultipleObjects(count, handles, all, timeout);
    require(calls < 2, "too many simulated waits");
    requested[calls++] = timeout;
    if (calls == 1) {ticks = 98; return WAIT_TIMEOUT;}
    ticks = 100;
    return second_result;
}
#define GetTickCount64 test_ticks
#define WaitForMultipleObjects test_wait
#include "../../src/nts_io.c"
#undef GetTickCount64
#undef WaitForMultipleObjects
static void check_deadline(DWORD end) {
    NtsJob j = {0};
    j.deadline = 100; ticks = 91; simulated = 1; calls = 0; second_result = end;
    HANDLE event = NULL;
    require(nts_wait(&j,1,&event)==end, "early timeout lost final event or deadline");
    require(calls==2 && requested[0]==9 && requested[1]==2,"absolute deadline accounting");
    simulated=0;
}
static const char *eval(Tcl_Interp *ip, const char *str) {
    require(Tcl_Eval(ip,str) == TCL_OK, Tcl_GetStringResult(ip)); return Tcl_GetStringResult(ip);
}

static void check_connect_ownership(struct sockaddr_in addr) {
    /* Keep the port reserved, without listening. The TCP attempt must fail
     * after acquiring its socket and event. UDP connect needs no listener. */
    SOCKET reserved = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    addr.sin_port = 0;
    require(reserved != INVALID_SOCKET && bind(reserved, (struct sockaddr *)&addr, sizeof addr) == 0,
            "reserve loopback port");
    int size = sizeof addr;
    require(getsockname(reserved, (struct sockaddr *)&addr, &size) == 0, "reserved port");
    NtsJob job = {0};
    job.cancel = CreateEventW(NULL, TRUE, FALSE, NULL);
    require(job.cancel != NULL, "cancellation event");
    unsigned short port = ntohs(addr.sin_port);
    DWORD before, after;
    for (int i = 0; i < 6; ++i) {
        if (i == 1) require(GetProcessHandleCount(GetCurrentProcess(), &before), "warmed handles");
        NtsSocket result;
        job.deadline = GetTickCount64() + 5000;
        require(nts_connect(&job, L"127.0.0.1", port, SOCK_DGRAM, &result), "UDP connect");
        require(result.fd != INVALID_SOCKET && result.event != WSA_INVALID_EVENT, "owned UDP handles");
        nts_close(&result);
        job.deadline = GetTickCount64() + 5000;
        require(!nts_connect(&job, L"127.0.0.1", port, SOCK_STREAM, &result), "refused TCP connection");
        require(result.fd == INVALID_SOCKET && result.event == WSA_INVALID_EVENT, "empty failed connection");
    }
    require(GetProcessHandleCount(GetCurrentProcess(), &after) && after <= before + 2,
            "failed attempts released their sockets and events");
    CloseHandle(job.cancel);
    closesocket(reserved);
}

int main(int argc,char **argv) {
    (void)argc;
    check_deadline(WAIT_TIMEOUT); check_deadline(WAIT_OBJECT_0);
    Tcl_FindExecutable(argv[0]);
    WSADATA w; require(WSAStartup(MAKEWORD(2,2),&w)==0,"Winsock");
    SOCKET server=socket(AF_INET,SOCK_STREAM,0);
    struct sockaddr_in addr={0}; addr.sin_family=AF_INET; addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    require(bind(server,(struct sockaddr*)&addr,sizeof addr)==0 && listen(server,8)==0,"loopback listener");
    int n=sizeof addr; require(getsockname(server,(struct sockaddr*)&addr,&n)==0,"local port");
    check_connect_ownership(addr);
    DWORD before=0,after=0; int timeouts=0;
    for(int i=0;i<96;i++) {
        if(i==32) require(GetProcessHandleCount(GetCurrentProcess(),&before),"initial handle count");
        Tcl_Interp *ip=Tcl_CreateInterp();
        eval(ip,"namespace eval ::machteld::network {}");Machteldnts_Register(ip);
        char str[128]; snprintf(str,sizeof str,"set j [::machteld::network::nts start 127.0.0.1 -port %u -timeout %d]",
                                ntohs(addr.sin_port),i%4==3?250:5000);
        Tcl_CmdInfo cmd; const char *name=eval(ip,str);
        require(Tcl_GetCommandInfo(ip,name,&cmd),"request command");
        NtsJob *j=cmd.objClientData; InterlockedIncrement(&j->refs);
        fd_set fds; FD_ZERO(&fds); FD_SET(server,&fds);
        struct timeval limit={2,0};require(select(0,&fds,NULL,NULL,&limit)==1,"client connected");
        SOCKET peer=accept(server,NULL,NULL);require(peer!=INVALID_SOCKET,"accept");
        switch(i%4) {
        case 0:
            require(!strcmp(eval(ip,"$j cancel; $j status"),"cancelled"),"cancel terminal");
            eval(ip,"$j close");break;
        case 1: eval(ip,"$j close");break;
        case 2: break; /* Interp deletion owns cancellation. */
        case 3:
            require(!strcmp(eval(ip,"catch {$j wait} msg opt; dict get $opt -errorcode"),"MACHTELD NTS timeout"),"lifetime deadline");
            ++timeouts;break;
        }
        Tcl_DeleteInterp(ip);
        ULONGLONG until=GetTickCount64()+3000;
        while(InterlockedCompareExchange(&j->refs,0,0)!=1 && GetTickCount64()<until)Sleep(1);
        require(InterlockedCompareExchange(&j->refs,0,0)==1,"Windows worker released its last reference");
        require(job_state(j)==(i%4==3?NTS_TIMEOUT:NTS_CANCELLED),"terminal state remained stable");
        release(j);closesocket(peer);
    }
    require(GetProcessHandleCount(GetCurrentProcess(),&after) && after<=before+4,"handle count stable after warm-up");
    printf("96 actual TLS connection lifetimes, %d deadlines, all workers released; handles %lu -> %lu\n",timeouts,before,after);
    closesocket(server);WSACleanup();Tcl_Finalize();return 0;
}
