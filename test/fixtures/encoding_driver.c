/* Exercise simultaneous first use from separate Tcl interpreters in one
 * process. Run in fresh processes to test an absent DLL and incomplete API. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

static const char *mode;
static LONG attempts, invalid;
static HANDLE start_event;
static HMODULE WINAPI observe_load(LPCWSTR name, HANDLE file, DWORD flags) {
    InterlockedIncrement(&attempts);
    if (wcscmp(name, L"icu.dll") || file || flags != LOAD_LIBRARY_SEARCH_SYSTEM32) InterlockedIncrement(&invalid);
    if (!strcmp(mode, "missing")) return NULL;
    return LoadLibraryExW(name, file, flags);
}
static FARPROC WINAPI observe_import(HMODULE h, LPCSTR symbol) {
    if (!strcmp(mode, "incomplete") && !strcmp(symbol, "ucsdet_close")) return NULL;
    return GetProcAddress(h, symbol);
}
#define LoadLibraryExW observe_load
#define GetProcAddress observe_import
#include "../../src/encoding_detect.c"
#undef LoadLibraryExW
#undef GetProcAddress

static DWORD WINAPI detect_in_thread(void *unused) {
    (void)unused;
    Tcl_Interp *interp = Tcl_CreateInterp();
    if (Machteldencoding_Init(interp) != TCL_OK) return 2;
    if (WaitForSingleObject(start_event, 5000) != WAIT_OBJECT_0) return 2;
    DWORD failed = 0;
    for (int i = 0; i < 40; ++i) {
        if (Tcl_Eval(interp, "set r [::machteld::encoding::detect [binary decode hex efbbbf616263]];"
                            "list [dict get $r status] [dict get $r encoding]") != TCL_OK ||
            strcmp(Tcl_GetStringResult(interp), !strcmp(mode, "system") ? "match UTF-8" : "unavailable {}")) {
            failed = 1;
            break;
        }
    }
    Tcl_DeleteInterp(interp);
    Tcl_FinalizeThread();
    return failed;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    mode = argv[1];
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    Tcl_FindExecutable(argv[0]);
    start_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!start_event) return 2;
    HANDLE threads[8];
    for (int i = 0; i < 8; ++i) {
        threads[i] = CreateThread(NULL, 0, detect_in_thread, NULL, 0, NULL);
        if (!threads[i]) return 2;
    }
    SetEvent(start_event);
    if (WaitForMultipleObjects(8, threads, TRUE, 30000) != WAIT_OBJECT_0) return 2;
    DWORD failed = 0;
    for (int i = 0; i < 8; ++i) {
        DWORD status;
        if (!GetExitCodeThread(threads[i], &status) || status) ++failed;
        CloseHandle(threads[i]);
    }
    CloseHandle(start_event);
    Tcl_Finalize();
    printf("encoding %s: 8 interpreters, 320 calls, %ld loads, %lu thread failures\n",
           mode, attempts, (unsigned long)failed);
    return failed || attempts != 1 || invalid;
}
