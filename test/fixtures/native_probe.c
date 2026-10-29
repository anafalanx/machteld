/* Test-only read-only process telemetry; never linked into Machteld. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>
#include <tlhelp32.h>
#include <tcl.h>

static unsigned long long ticks(FILETIME value) {
    return ((unsigned long long)value.dwHighDateTime << 32) | value.dwLowDateTime;
}

static void put(Tcl_Interp *interp, Tcl_Obj *dict, const char *name,
                unsigned long long value) {
    Tcl_DictObjPut(interp, dict, Tcl_NewStringObj(name, -1),
                   Tcl_NewWideIntObj((Tcl_WideInt)value));
}

static int metrics(void *data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    int cpu_only = data != NULL;
    Tcl_WideInt requested = (Tcl_WideInt)GetCurrentProcessId();
    if (objc > 2 || (objc == 2 && Tcl_GetWideIntFromObj(interp, objv[1], &requested) != TCL_OK))
        return TCL_ERROR;
    if (requested <= 0 || (unsigned long long)requested > MAXDWORD) return TCL_ERROR;
    DWORD id = (DWORD)requested;
    HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | SYNCHRONIZE, FALSE, id);
    if (process == NULL) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("process unavailable", -1));
        return TCL_ERROR;
    }
    FILETIME created, exited, kernel, user;
    PROCESS_MEMORY_COUNTERS_EX memory = {0};
    memory.cb = sizeof(memory);
    DWORD handles = 0;
    unsigned long long cycles = 0;
    int ok = GetProcessTimes(process, &created, &exited, &kernel, &user) &&
             GetProcessHandleCount(process, &handles) &&
             GetProcessMemoryInfo(process, (PROCESS_MEMORY_COUNTERS *)&memory, sizeof(memory)) &&
             QueryProcessCycleTime(process, &cycles);
    DWORD state = WaitForSingleObject(process, 0);
    CloseHandle(process);
    if (!ok || state == WAIT_FAILED) return TCL_ERROR;
    unsigned threads = 0;
    if (!cpu_only) {
        HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if (snapshot == INVALID_HANDLE_VALUE) return TCL_ERROR;
        THREADENTRY32 entry = {0};
        entry.dwSize = sizeof(entry);
        if (Thread32First(snapshot, &entry)) {
            do { if (entry.th32OwnerProcessID == id) threads++; }
            while (Thread32Next(snapshot, &entry));
        }
        CloseHandle(snapshot);
    }
    Tcl_Obj *result = Tcl_NewDictObj();
    put(interp, result, "pid", id);
    put(interp, result, "alive", state == WAIT_TIMEOUT);
    put(interp, result, "handles", handles);
    if (!cpu_only) put(interp, result, "threads", threads);
    put(interp, result, "cpu_us", (ticks(kernel) + ticks(user)) / 10);
    put(interp, result, "cycles", cycles);
    put(interp, result, "private_bytes", (unsigned long long)memory.PrivateUsage);
    put(interp, result, "working_set", (unsigned long long)memory.WorkingSetSize);
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
}

DLLEXPORT int Nativeprobe_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "9.0", 0) == NULL) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "native_metrics", metrics, NULL, NULL);
    Tcl_CreateObjCommand(interp, "native_cpu", metrics, (void *)1, NULL);
    return Tcl_PkgProvide(interp, "nativeprobe", "1.0");
}
