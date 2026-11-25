/* Run the packaged host's desktop regression on a private, never-switched
 * desktop. The awaited job owns the test's fixture windows and descendants. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static HANDLE inherit_stream(DWORD stream, DWORD access) {
    HANDLE original = GetStdHandle(stream), copy = NULL;
    if (original && original != INVALID_HANDLE_VALUE &&
        DuplicateHandle(GetCurrentProcess(), original, GetCurrentProcess(), &copy,
                        0, TRUE, DUPLICATE_SAME_ACCESS)) return copy;
    SECURITY_ATTRIBUTES sa = {.nLength = sizeof(sa), .bInheritHandle = TRUE};
    return CreateFileW(L"NUL", access, FILE_SHARE_READ | FILE_SHARE_WRITE,
                       &sa, OPEN_EXISTING, 0, NULL);
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 4) return 2;
    /* All dynamic arguments are Windows file paths. A valid file name cannot
     * contain a quote or end in a directory separator. */
    size_t count = 32;
    for (int i = 1; i < 4; i++) {
        size_t n = wcslen(argv[i]);
        if (!n || n > 32767 || wcschr(argv[i], L'"') || argv[i][n - 1] == L'\\' ||
                argv[i][n - 1] == L'/') return 2;
        count += n;
    }
    if (count > 32767) return 2;
    wchar_t *line = calloc(count, sizeof(*line));
    if (!line) return 2;
    swprintf(line, count, L"\"%ls\" \"%ls\" --windows \"%ls\"", argv[1], argv[2], argv[3]);

    int result = 1;
    const char *step = "desktop setup";
    DWORD error = 0, needed;
    wchar_t station[256], name[96], full[384];
    swprintf(name, 96, L"MachteldDesktopTest-%lu-%llu", GetCurrentProcessId(), GetTickCount64());
    HDESK original = GetThreadDesktop(GetCurrentThreadId());
    HDESK desktop = NULL;
    HANDLE job = NULL, streams[3] = {NULL};
    STARTUPINFOEXW startup = {0};
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    int attributes_ready = 0;
    PROCESS_INFORMATION process = {0};
    if (!GetUserObjectInformationW(GetProcessWindowStation(), UOI_NAME, station, sizeof(station), &needed) ||
            !SetEnvironmentVariableW(L"MACHTELD_TEST_EXPECT_DESKTOP", name)) goto failed;
    swprintf(full, 384, L"%ls\\%ls", station, name);
    desktop = CreateDesktopW(name, NULL, NULL, 0, GENERIC_ALL, NULL);
    if (!desktop || !SetThreadDesktop(desktop)) goto failed;

    step = "fixture job";
    job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)))
        goto failed;
    step = "fixture streams";
    streams[0] = inherit_stream(STD_INPUT_HANDLE, GENERIC_READ);
    streams[1] = inherit_stream(STD_OUTPUT_HANDLE, GENERIC_WRITE);
    streams[2] = inherit_stream(STD_ERROR_HANDLE, GENERIC_WRITE);
    for (int i = 0; i < 3; i++) if (streams[i] == INVALID_HANDLE_VALUE) goto failed;

    SIZE_T size = 0;
    step = "process attributes";
    InitializeProcThreadAttributeList(NULL, 2, 0, &size);
    if (!size || !(attributes = malloc(size)) ||
            !InitializeProcThreadAttributeList(attributes, 2, 0, &size)) goto failed;
    attributes_ready = 1;
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
            &job, sizeof(job), NULL, NULL) ||
        !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            streams, sizeof(streams), NULL, NULL)) goto failed;

    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.lpDesktop = full;
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_FORCEOFFFEEDBACK;
    startup.StartupInfo.hStdInput = streams[0];
    startup.StartupInfo.hStdOutput = streams[1];
    startup.StartupInfo.hStdError = streams[2];
    startup.lpAttributeList = attributes;
    step = "private host launch";
    if (!CreateProcessW(argv[1], line, NULL, NULL, TRUE, EXTENDED_STARTUPINFO_PRESENT | DETACHED_PROCESS,
            NULL, NULL, &startup.StartupInfo, &process)) goto failed;
    step = "private host exit";
    DWORD wait = WaitForSingleObject(process.hProcess, 90000), code;
    if (wait == WAIT_TIMEOUT) {
        error = WAIT_TIMEOUT;
        goto failed;
    }
    if (wait != WAIT_OBJECT_0 || !GetExitCodeProcess(process.hProcess, &code)) goto failed;
    result = code == 0 ? 0 : 1;
    goto cleanup;
failed:
    if (!error) error = GetLastError();
    fprintf(stderr, "desktop_runner: %s failed (Windows error %lu)\n", step, error);
cleanup:
    if (job) CloseHandle(job);
    if (process.hThread) CloseHandle(process.hThread);
    if (process.hProcess) CloseHandle(process.hProcess);
    if (attributes_ready) DeleteProcThreadAttributeList(attributes);
    free(attributes);
    for (int i = 0; i < 3; ++i)
        if (streams[i] && streams[i] != INVALID_HANDLE_VALUE) CloseHandle(streams[i]);
    if (desktop) {
        SetThreadDesktop(original);
        CloseDesktop(desktop);
    }
    free(line);
    return result;
}
