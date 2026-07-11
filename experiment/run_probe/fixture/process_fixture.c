#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

enum {
    EXIT_USAGE = 64,
    EXIT_PIDFILE = 65,
    EXIT_ENCODING = 66,
    EXIT_OUTPUT = 67
};

static int write_all(HANDLE stream, const char *bytes, DWORD length) {
    DWORD offset = 0;
    while (offset < length) {
        DWORD written = 0;
        if (!WriteFile(stream, bytes + offset, length - offset, &written, NULL) ||
            written == 0) {
            return 0;
        }
        offset += written;
    }
    return 1;
}

static char *utf8_from_wide(const wchar_t *text, DWORD *length) {
    int needed = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1,
                                     NULL, 0, NULL, NULL);
    if (needed <= 0) {
        return NULL;
    }

    char *result = (char *)malloc((size_t)needed);
    if (result == NULL) {
        return NULL;
    }
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, -1,
                            result, needed, NULL, NULL) != needed) {
        free(result);
        return NULL;
    }

    *length = (DWORD)(needed - 1);
    return result;
}

static int write_pidfile(void) {
    const wchar_t *path = _wgetenv(L"MACHTELD_PROBE_PIDFILE");
    if (path == NULL || path[0] == L'\0') {
        return 0;
    }

    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        return 0;
    }

    char pid[32];
    int length = snprintf(pid, sizeof(pid), "%lu",
                          (unsigned long)GetCurrentProcessId());
    int ok = length > 0 && (size_t)length < sizeof(pid) &&
             write_all(file, pid, (DWORD)length) &&
             FlushFileBuffers(file);
    if (!CloseHandle(file)) {
        ok = 0;
    }
    return ok;
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 3) {
        return EXIT_USAGE;
    }

    /* The checker uses this out-of-band marker to prove every case really
       launched the fixture, including fast ok/fail cases. */
    if (!write_pidfile()) {
        return EXIT_PIDFILE;
    }

    if (wcscmp(argv[1], L"hang") == 0) {
        Sleep(5000);
        return 0;
    }

    int exit_code;
    if (wcscmp(argv[1], L"ok") == 0) {
        exit_code = 0;
    } else if (wcscmp(argv[1], L"fail") == 0) {
        exit_code = 7;
    } else {
        return EXIT_USAGE;
    }

    DWORD payload_length = 0;
    char *payload = utf8_from_wide(argv[2], &payload_length);
    if (payload == NULL) {
        return EXIT_ENCODING;
    }

    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
    int ok = out != NULL && out != INVALID_HANDLE_VALUE &&
             err != NULL && err != INVALID_HANDLE_VALUE &&
             write_all(out, payload, payload_length) &&
             write_all(err, "E:", 2) &&
             write_all(err, payload, payload_length);
    free(payload);

    return ok ? exit_code : EXIT_OUTPUT;
}
