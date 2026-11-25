/* A cooperating GUI process for the attended-child acceptance test. It reports
 * its own window state; its only control inputs are files in its private cwd. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

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

int
wmain(int argc, wchar_t **argv)
{
    if (argc != 4) return 2;
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
    HWND w = CreateWindowExW(0, argv[2], L"Machteld window fixture", WS_OVERLAPPEDWINDOW,
                             CW_USEDEFAULT, CW_USEDEFAULT, 420, 260, NULL, NULL, instance, NULL);
    if (w == NULL) return 1;
    ShowWindow(w, SW_SHOWNOACTIVATE);
    if (wcscmp(argv[3], L"iconic") == 0) {
        ShowWindow(w, SW_SHOWMINNOACTIVE);
    } else if (wcscmp(argv[3], L"hidden") == 0) {
        ShowWindow(w, SW_HIDE);
    } else if (wcscmp(argv[3], L"offscreen") == 0) {
        int outside = GetSystemMetrics(SM_XVIRTUALSCREEN) + GetSystemMetrics(SM_CXVIRTUALSCREEN) + 256;
        if (!SetWindowPos(w, NULL, outside, 100, 420, 260, SWP_NOACTIVATE | SWP_NOZORDER)) return 1;
    } else if (wcscmp(argv[3], L"normal") != 0) {
        return 2;
    }
    if (!report(L"opened", w)) return 1;

    while (GetTickCount64() < due) {
        MSG message;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
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
