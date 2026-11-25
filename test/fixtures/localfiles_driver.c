/* Synthetic provider transitions using real file handles, channel ownership
 * and a second OS thread. Only the metadata and Cloud Files residency query
 * are substituted. No real user's cloud files or account are needed. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string.h>
#include <stdio.h>
#include <wchar.h>

enum Scenario { LOCAL, LISTED_THEN_EVICTED, EVICTED_AT_REOPEN, PINNED_PARTIAL,
                MISSING_RANGE, RESIDENT, DENIED };
static enum Scenario scenario;
static int queries, reopens, violations;

static BOOL WINAPI classify(HANDLE h, FILE_INFO_BY_HANDLE_CLASS kind, void *buf, DWORD sz) {
    if (!GetFileInformationByHandleEx(h, kind, buf, sz)) return FALSE;
    if (kind != FileAttributeTagInfo) return TRUE;
    ++queries;
    FILE_ATTRIBUTE_TAG_INFO *info = buf;
    if (scenario == EVICTED_AT_REOPEN && queries == 2) info->FileAttributes |= FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS;
    if (scenario == LISTED_THEN_EVICTED) info->FileAttributes |= FILE_ATTRIBUTE_RECALL_ON_OPEN;
    if (scenario == DENIED) {SetLastError(ERROR_ACCESS_DENIED); return FALSE;}
    if (scenario == PINNED_PARTIAL || scenario == MISSING_RANGE || scenario == RESIDENT) {
        info->FileAttributes = FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_PINNED;
        info->ReparseTag = IO_REPARSE_TAG_CLOUD_3;
    }
    return TRUE;
}
static HANDLE WINAPI observe_open(LPCWSTR name, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES sec,
                                  DWORD disposition, DWORD flags, HANDLE template) {
    DWORD required = FILE_FLAG_OPEN_NO_RECALL | FILE_FLAG_OPEN_REPARSE_POINT;
    if ((flags & required) != required) ++violations;
    if (access != FILE_READ_ATTRIBUTES) {
        if (access != GENERIC_READ || (share & (FILE_SHARE_WRITE | FILE_SHARE_DELETE))) ++violations;
        ++reopens;
    }
    return CreateFileW(name, access, share, sec, disposition, flags, template);
}
static DWORD WINAPI mock_state(DWORD attr, DWORD tag) {
    (void)attr; (void)tag;
    return scenario == PINNED_PARTIAL ? 0x11u : 1u;
}
static HRESULT WINAPI mock_ranges(HANDLE h, int kind, LARGE_INTEGER offset, LARGE_INTEGER length,
                                  void *buf, DWORD buflen, DWORD *returned) {
    (void)h;
    LARGE_INTEGER *range = buf;
    if (kind != 1 || offset.QuadPart != 0 || buflen != sizeof(*range)*2) ++violations;
    range[0].QuadPart = 0;
    range[1].QuadPart = scenario == MISSING_RANGE ? length.QuadPart - 1 : length.QuadPart;
    *returned = 2 * sizeof(*range);
    return S_OK;
}
static FARPROC WINAPI mock_proc(HMODULE h, LPCSTR name) {
    if (!strcmp(name, "RtlSetThreadPlaceholderCompatibilityMode")) return GetProcAddress(h, name);
    if (!strcmp(name, "CfGetPlaceholderStateFromAttributeTag")) {
        union {FARPROC address; DWORD (WINAPI *fn)(DWORD, DWORD);} u = {.fn = mock_state};
        return u.address;
    }
    union {FARPROC address; HRESULT (WINAPI *fn)(HANDLE, int, LARGE_INTEGER, LARGE_INTEGER, void *, DWORD, DWORD *);} u = {.fn = mock_ranges};
    return u.address;
}

#define GetFileInformationByHandleEx classify
#define CreateFileW observe_open
#define GetProcAddress mock_proc
#include "../../src/localfiles.c"
#undef GetFileInformationByHandleEx
#undef CreateFileW
#undef GetProcAddress

typedef struct {HANDLE data; LPCWSTR path;} Reader;
static DWORD WINAPI read_elsewhere(void *arg) {
    Reader *r = arg;
    HANDLE exclusive = CreateFileW(r->path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (exclusive != INVALID_HANDLE_VALUE) {CloseHandle(exclusive); return 1;}
    if (GetLastError() != ERROR_SHARING_VIOLATION) return 2;
    char bytes[3];
    DWORD n = 0;
    return (!ReadFile(r->data, bytes, sizeof(bytes), &n, NULL) || n != 3 || memcmp(bytes, "ABC", 3)) ? 3 : 0;
}

static int observe_mode(void *client, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)client; (void)objc; (void)objv;
    SetPlaceholderMode mode = mode_api();
    CHAR old = mode(1);
    mode(old);
    if (old != 1) return files_error(interp, "state", "callback inherited native placeholder visibility");
    return TCL_OK;
}
int main(int argc, char **argv) {
    (void)argc;
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    Tcl_FindExecutable(argv[0]);
    Tcl_Interp *interp = Tcl_CreateInterp();
    if (Machteldfiles_Init(interp) != TCL_OK) return 2;
    SetPlaceholderMode mode = mode_api();
    if (!mode) return 2;
    CHAR original = mode(1);
    Tcl_CreateObjCommand(interp, "observe_mode", observe_mode, NULL, NULL);
    const char *setup = "set ch [file tempfile path]; puts -nonewline $ch ABC; close $ch;"
                        "set saved [::machteld::files::entries [file dirname $path]]";
    if (Tcl_Eval(interp, setup) != TCL_OK) {puts(Tcl_GetStringResult(interp)); return 2;}
    int failures = 0;
    DWORD before, after;
    if (Tcl_Eval(interp, "::machteld::files::entries [file dirname $path] observe_mode") != TCL_OK ||
        !GetProcessHandleCount(GetCurrentProcess(), &before)) return 2;
    for (int i = 0; i < 25; ++i) {
        if (Tcl_Eval(interp, "::machteld::files::entries [file dirname $path] observe_mode") != TCL_OK) ++failures;
    }
    if (!GetProcessHandleCount(GetCurrentProcess(), &after) || before != after || mode(1) != 1) ++failures;
    for (scenario = LOCAL; scenario <= DENIED; ++scenario) {
        queries = reopens = 0;
        int rc = Tcl_Eval(interp, "::machteld::files::openlocal $path");
        if (scenario == LOCAL || scenario == RESIDENT) {
            if (rc != TCL_OK) {puts(Tcl_GetStringResult(interp)); ++failures; continue;}
            Tcl_Channel channel = Tcl_GetChannel(interp, Tcl_GetStringResult(interp), NULL);
            Reader reader;
            if (!channel || Tcl_GetChannelHandle(channel, TCL_READABLE, &reader.data) != TCL_OK) return 2;
            reader.path = native_path(interp, Tcl_GetVar2Ex(interp, "path", NULL, 0));
            HANDLE worker = CreateThread(NULL, 0, read_elsewhere, &reader, 0, NULL);
            DWORD result = 1;
            if (!worker || WaitForSingleObject(worker, 5000) != WAIT_OBJECT_0) return 2;
            GetExitCodeThread(worker, &result);
            CloseHandle(worker);
            if (result || Tcl_UnregisterChannel(interp, channel) != TCL_OK) ++failures;
        } else {
            const char *want = scenario == DENIED ? "MACHTELD FILES denied" : "MACHTELD FILES offline";
            const char *code = Tcl_GetVar(interp, "errorCode", TCL_GLOBAL_ONLY);
            if (rc != TCL_ERROR || !code || strcmp(code, want)) ++failures;
        }
        if (reopens != ((scenario == LISTED_THEN_EVICTED || scenario == DENIED) ? 0 : 1)) ++failures;
    }
    if (Tcl_Eval(interp, "file delete -- $path") != TCL_OK) ++failures;
    if (mode(original) != 1) ++failures;
    Tcl_DeleteInterp(interp);
    Tcl_Finalize();
    printf("files provider driver: 7 scenarios, enumeration handles %lu -> %lu, %d failures, %d flag violations\n",
           (unsigned long)before, (unsigned long)after, failures, violations);
    return failures || violations;
}
