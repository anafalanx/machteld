/* Disposable, account-free Windows Cloud Files provider for the optional
 * live test in localfiles_test.tcl. Build in an x64 Windows SDK prompt:
 *   cl /nologo /W4 /O2 cloud_files_provider.c cldapi.lib
 * The caller supplies an empty NTFS directory. The provider owns registration,
 * the test data and cleanup. EOF or a lost parent also terminates the test. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winternl.h>
#include <cfapi.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

static LONG fetch_count;
static void CALLBACK count_fetch(const CF_CALLBACK_INFO *info, const CF_CALLBACK_PARAMETERS *p) {
    InterlockedIncrement(&fetch_count);
    CF_OPERATION_INFO op = {0};
    op.StructSize = sizeof(op);
    op.ConnectionKey = info->ConnectionKey;
    op.TransferKey = info->TransferKey;
    op.Type = CF_OPERATION_TYPE_TRANSFER_DATA;
    CF_OPERATION_PARAMETERS args = {0};
    args.ParamSize = (ULONG)(offsetof(CF_OPERATION_PARAMETERS, TransferData) + sizeof(args.TransferData));
    args.TransferData.Offset = p->FetchData.RequiredFileOffset;
    args.TransferData.Length = p->FetchData.RequiredLength;
    args.TransferData.CompletionStatus = (NTSTATUS)0xc0000001;
    CfExecute(&op, &args);
}

static HRESULT make_resident(const wchar_t *path, BOOL pinned) {
    HANDLE h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_NEW, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
    DWORD n;
    HRESULT hr = WriteFile(h, "ABC", 3, &n, NULL) ? S_OK : HRESULT_FROM_WIN32(GetLastError());
    const char *id = pinned ? "pinned" : "resident";
    if (SUCCEEDED(hr)) hr = CfConvertToPlaceholder(h, id, (DWORD)strlen(id), CF_CONVERT_FLAG_MARK_IN_SYNC, NULL, NULL);
    if (SUCCEEDED(hr) && pinned) hr = CfSetPinState(h, CF_PIN_STATE_PINNED, CF_SET_PIN_FLAG_NONE, NULL);
    CloseHandle(h);
    return hr;
}

static HRESULT evict(const wchar_t *path) {
    HANDLE h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
                           FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_OPEN_NO_RECALL, NULL);
    if (h == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
    LARGE_INTEGER start = {0}, length;
    length.QuadPart = -1;
    HRESULT hr = CfDehydratePlaceholder(h, start, length, CF_DEHYDRATE_FLAG_NONE, NULL);
    CloseHandle(h);
    return hr;
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 2) return 2;
    const wchar_t *root = argv[1];
    wchar_t resident[MAX_PATH], pinned[MAX_PATH], search[MAX_PATH];
    if (swprintf_s(resident, MAX_PATH, L"%s\\resident.bin", root) < 0 ||
        swprintf_s(pinned, MAX_PATH, L"%s\\pinned.bin", root) < 0 ||
        swprintf_s(search, MAX_PATH, L"%s\\*", root) < 0) return 2;
    WIN32_FIND_DATAW item;
    HANDLE list = FindFirstFileW(search, &item);
    if (list == INVALID_HANDLE_VALUE) return 2;
    BOOL empty = TRUE;
    do {
        if (wcscmp(item.cFileName,L".") && wcscmp(item.cFileName,L"..")) empty = FALSE;
    } while (FindNextFileW(list, &item));
    FindClose(list);
    if (!empty) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    CF_SYNC_REGISTRATION reg = {0};
    reg.StructSize = sizeof(reg);
    reg.ProviderName = L"Machteld disposable Cloud Files fixture";
    reg.ProviderVersion = L"1";
    CF_SYNC_POLICIES policy = {0};
    policy.StructSize = sizeof(policy);
    policy.Hydration.Primary = CF_HYDRATION_POLICY_PARTIAL;
    policy.Hydration.Modifier = CF_HYDRATION_POLICY_MODIFIER_AUTO_DEHYDRATION_ALLOWED;
    policy.Population.Primary = CF_POPULATION_POLICY_ALWAYS_FULL;
    HRESULT hr = CfRegisterSyncRoot(root, &reg, &policy, CF_REGISTER_FLAG_NONE);
    if (FAILED(hr)) {printf("register %08lx\n", (ULONG)hr); return 1;}
    CF_CONNECTION_KEY key;
    CF_CALLBACK_REGISTRATION callbacks[] = {{CF_CALLBACK_TYPE_FETCH_DATA, count_fetch}, CF_CALLBACK_REGISTRATION_END};
    hr = CfConnectSyncRoot(root, callbacks, NULL, CF_CONNECT_FLAG_NONE, &key);
    BOOL connected = SUCCEEDED(hr);
    if (connected) {
        CF_PLACEHOLDER_CREATE_INFO online = {0};
        online.RelativeFileName = L"online-only.bin";
        online.FileIdentity = "online";
        online.FileIdentityLength = 6;
        online.FsMetadata.BasicInfo.FileAttributes = FILE_ATTRIBUTE_NORMAL;
        online.FsMetadata.FileSize.QuadPart = 3;
        online.Flags = CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC;
        hr = CfCreatePlaceholders(root, &online, 1, CF_CREATE_FLAG_NONE, NULL);
        if (SUCCEEDED(hr)) hr = online.Result;
    }
    if (SUCCEEDED(hr)) hr = make_resident(resident, FALSE);
    if (SUCCEEDED(hr)) hr = make_resident(pinned, TRUE);
    if (SUCCEEDED(hr)) {
        puts("ready");
        ULONGLONG until = GetTickCount64() + 90000;
        while (GetTickCount64() < until) {
            DWORD available = 0;
            if (!PeekNamedPipe(GetStdHandle(STD_INPUT_HANDLE), NULL, 0, NULL, &available, NULL)) break;
            if (!available) {Sleep(20); continue;}
            char line[32];
            if (!fgets(line, sizeof(line), stdin) || !strncmp(line, "stop", 4)) break;
            if (!strncmp(line, "evict", 5)) printf("evict %08lx\n", (ULONG)evict(resident));
            else {hr = E_INVALIDARG; break;}
        }
    } else printf("provider setup %08lx\n", (ULONG)hr);
    if (connected && FAILED(CfDisconnectSyncRoot(key))) hr = E_FAIL;
    if (FAILED(CfUnregisterSyncRoot(root))) hr = E_FAIL;
    printf("fetches %ld\n", fetch_count);
    return FAILED(hr) || fetch_count != 0;
}
