/* A cooperating GUI process for the attended-child acceptance test. It reports
 * its own window state; its only control inputs are files in its private cwd. */
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <shobjidl.h>

#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static int
report(const wchar_t *name, HWND window)
{
    STARTUPINFOW startup = {0};
    RECT rect = {0};
    startup.cb = sizeof(startup);
    GetStartupInfoW(&startup);
    if (window != NULL && !GetWindowRect(window, &rect)) return 0;

    /* Rename after close so that the test always reads a complete record. */
    FILE *file = _wfopen(L"writing.tmp", L"wb");
    if (file == NULL) return 0;
    int count = fprintf(file,
        "pid %lu showSet %d show %u visible %d iconic %d onScreen %d width %ld height %ld\n",
        GetCurrentProcessId(), !!(startup.dwFlags & STARTF_USESHOWWINDOW),
        (unsigned)startup.wShowWindow, window != NULL && IsWindowVisible(window),
        window != NULL && IsIconic(window),
        window != NULL && MonitorFromRect(&rect, MONITOR_DEFAULTTONULL) != NULL,
        rect.right - rect.left, rect.bottom - rect.top);
    int closed = fclose(file);
    return count > 0 && closed == 0 && MoveFileW(L"writing.tmp", name);
}

static int
handoff(void)
{
    /* Keep the exact class argument and cwd. The descendant acknowledges
     * readiness only after this original process has exited. */
    wchar_t parent[32];
    swprintf(parent, 32, L"%lu", GetCurrentProcessId());
    if (!SetEnvironmentVariableW(L"MACHTELD_WINDOW_FIXTURE_PARENT_PID", parent)) return 1;
    wchar_t *line = _wcsdup(GetCommandLineW());
    if (line == NULL) return 1;
    STARTUPINFOW startup = {0};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process;
    BOOL started = CreateProcessW(NULL, line, NULL, NULL, FALSE, 0, NULL, NULL,
                                  &startup, &process);
    free(line);
    if (!started) return 1;
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return 0;
}

static HWND create_window(HINSTANCE instance, const wchar_t *class_name, int tiny)
{
    return CreateWindowExW(0, class_name, L"Machteld window fixture",
        tiny ? WS_POPUP : WS_OVERLAPPEDWINDOW, 80, 80,
        tiny ? 4 : 420, tiny ? 4 : 260, NULL, NULL, instance, NULL);
}

/* Create real Windows shell links without changing any association. */
static int create_shortcut(const wchar_t *link_path, const wchar_t *directory,
                           const wchar_t *target, const wchar_t *arguments)
{
    wchar_t self[32768];
    int hide_archive = target != NULL;
    if (!target) {
        DWORD n = GetModuleFileNameW(NULL, self, 32768);
        if (!n || n >= 32768) return 1;
        target = self;
    }
    if (FAILED(CoInitializeEx(NULL, COINIT_APARTMENTTHREADED))) return 1;
    IShellLinkW *link = NULL;
    IPersistFile *persist = NULL;
    HRESULT result = CoCreateInstance(&CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER,
                                      &IID_IShellLinkW, (void **)&link);
    if (SUCCEEDED(result)) result = IShellLinkW_SetPath(link, target);
    if (SUCCEEDED(result)) result = IShellLinkW_SetArguments(link, arguments);
    if (SUCCEEDED(result) && hide_archive) result = IShellLinkW_SetShowCmd(link, SW_HIDE);
    if (SUCCEEDED(result)) result = IShellLinkW_SetWorkingDirectory(link, directory);
    if (SUCCEEDED(result)) result = IShellLinkW_QueryInterface(link, &IID_IPersistFile, (void **)&persist);
    if (SUCCEEDED(result)) result = IPersistFile_Save(persist, link_path, TRUE);
    if (persist) IPersistFile_Release(persist);
    if (link) IShellLinkW_Release(link);
    CoUninitialize();
    return FAILED(result) ? 1 : 0;
}

int
wmain(int argc, wchar_t **argv)
{
    if (argc == 2 && wcscmp(argv[1], L"--record-open") == 0) return report(L"shell-opened", NULL) ? 0 : 1;
    if (argc == 4 && wcscmp(argv[1], L"--make-document") == 0)
        return create_shortcut(argv[2], argv[3], NULL, L"--record-open");
    if (argc == 6 && wcscmp(argv[1], L"--make-archive-link") == 0)
        return create_shortcut(argv[2], argv[3], argv[4], argv[5]);
    if (argc != 4) return 2;
    /* An isolated-desktop runner can demand a particular desktop. Check
     * before creating a window, including in the handoff descendant. */
    wchar_t expected[256], actual[256];
    DWORD expected_length = GetEnvironmentVariableW(L"MACHTELD_TEST_EXPECT_DESKTOP", expected, 256);
    if (expected_length) {
        DWORD copied;
        if (expected_length >= 256 || !GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),
                UOI_NAME, actual, sizeof(actual), &copied) || wcscmp(actual, expected)) return 3;
    }
    if (wcscmp(argv[1], L"handoff") == 0) {
        wchar_t text[32];
        DWORD n = GetEnvironmentVariableW(L"MACHTELD_WINDOW_FIXTURE_PARENT_PID", text, 32);
        if (n == 0) return handoff();
        if (n >= 32) return 2;
        HANDLE original = OpenProcess(SYNCHRONIZE, FALSE, wcstoul(text, NULL, 10));
        if (original != NULL) {
            DWORD exited = WaitForSingleObject(original, 5000);
            CloseHandle(original);
            if (exited != WAIT_OBJECT_0) return 1;
        }
    } else if (wcscmp(argv[1], L"direct") != 0) {
        return 2;
    }

    if (!report(L"started", NULL)) return 1;
    ULONGLONG due = GetTickCount64() + 60000;
    while (GetFileAttributesW(L"open-window") == INVALID_FILE_ATTRIBUTES) {
        if (GetTickCount64() > due) return 1;
        Sleep(10);
    }

    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW klass = {0};
    klass.hInstance = instance;
    klass.lpfnWndProc = DefWindowProcW;
    klass.lpszClassName = argv[2];
    if (!RegisterClassW(&klass)) return 1;
    int tiny = wcscmp(argv[3], L"tiny") == 0;
    HWND w = create_window(instance, argv[2], tiny);
    if (w == NULL) return 1;
    int startup_mode = wcscmp(argv[3], L"startup") == 0;
    STARTUPINFOW startup = { .cb = sizeof(startup) };
    GetStartupInfoW(&startup);
    ShowWindow(w, startup_mode && (startup.dwFlags & STARTF_USESHOWWINDOW)
                     ? startup.wShowWindow : SW_SHOWNOACTIVATE);
    if (wcscmp(argv[3], L"iconic") == 0) {
        ShowWindow(w, SW_SHOWMINNOACTIVE);
    } else if (wcscmp(argv[3], L"hidden") == 0) {
        ShowWindow(w, SW_HIDE);
    } else if (wcscmp(argv[3], L"offscreen") == 0) {
        int outside = GetSystemMetrics(SM_XVIRTUALSCREEN) + GetSystemMetrics(SM_CXVIRTUALSCREEN) + 256;
        if (!SetWindowPos(w, NULL, outside, 100, 420, 260, SWP_NOACTIVATE | SWP_NOZORDER)) return 1;
    } else if (!tiny && !startup_mode && wcscmp(argv[3], L"normal") != 0) {
        return 2;
    }
    if (!report(L"opened", w)) return 1;

    while (GetTickCount64() < due) {
        MSG message;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if (!IsWindow(w)) return 0; /* DefWindowProc accepted WM_CLOSE. */
        if (DeleteFileW(L"recreate")) {
            DestroyWindow(w);
            w = create_window(instance, argv[2], tiny);
            if (!w) return 1;
            ShowWindow(w, SW_SHOWNOACTIVATE);
            if (!report(L"recreated", w)) return 1;
        }
        if (DeleteFileW(L"minimize")) {
            ShowWindow(w, SW_SHOWMINNOACTIVE);
            if (!report(L"minimized", w)) return 1;
        }
        if (DeleteFileW(L"observe") && !report(L"observed", w)) return 1;
        if (DeleteFileW(L"finish")) break;
        MsgWaitForMultipleObjects(0, NULL, FALSE, 15, QS_ALLINPUT);
    }
    DestroyWindow(w);
    return 0;
}
