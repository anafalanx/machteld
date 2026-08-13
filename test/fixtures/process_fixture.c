#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

enum {
    EXIT_USAGE = 64,
    EXIT_PIDFILE = 65,
    EXIT_ENCODING = 66,
    EXIT_OUTPUT = 67,
    EXIT_LAUNCH = 68,
    EXIT_ENVIRONMENT = 69
};

static int write_all(HANDLE stream, const void *buffer, DWORD length) {
    const unsigned char *bytes = (const unsigned char *)buffer;
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

static int write_text(HANDLE stream, const char *text) {
    size_t length = strlen(text);
    return length <= UINT32_MAX && write_all(stream, text, (DWORD)length);
}

static int write_pid_path(const wchar_t *path, DWORD pid) {
    if (path == NULL || path[0] == L'\0') {
        return 0;
    }
    HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        return 0;
    }
    char text[32];
    int length = snprintf(text, sizeof(text), "%lu", (unsigned long)pid);
    int ok = length > 0 && (size_t)length < sizeof(text) &&
             write_all(file, text, (DWORD)length) && FlushFileBuffers(file);
    if (!CloseHandle(file)) {
        ok = 0;
    }
    return ok;
}

static int write_environment_pidfile(void) {
    const wchar_t *path = _wgetenv(L"MACHTELD_TEST_PIDFILE");
    return path == NULL || path[0] == L'\0' ||
           write_pid_path(path, GetCurrentProcessId());
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

static DWORD milliseconds(const wchar_t *text) {
    wchar_t *end = NULL;
    unsigned long value = wcstoul(text, &end, 10);
    if (end == text || *end != L'\0' || value > UINT32_MAX) {
        return UINT32_MAX;
    }
    return (DWORD)value;
}

static int descendant_child(DWORD hold_ms) {
    Sleep(hold_ms);
    if (!write_text(GetStdHandle(STD_OUTPUT_HANDLE), "DESCENDANT-OUT\n") ||
        !write_text(GetStdHandle(STD_ERROR_HANDLE), "DESCENDANT-ERR\n")) {
        return EXIT_OUTPUT;
    }
    return 0;
}

static int descendant_parent(DWORD hold_ms, const wchar_t *pidfile) {
    wchar_t executable[MAX_PATH];
    DWORD size = GetModuleFileNameW(NULL, executable, MAX_PATH);
    if (size == 0 || size == MAX_PATH) {
        return EXIT_LAUNCH;
    }

    size_t command_size = wcslen(executable) + 80;
    wchar_t *command = (wchar_t *)calloc(command_size, sizeof(wchar_t));
    if (command == NULL) {
        return EXIT_LAUNCH;
    }
    int n = swprintf(command, command_size, L"\"%ls\" descendant-child %lu",
                     executable, (unsigned long)hold_ms);
    if (n < 0 || (size_t)n >= command_size) {
        free(command);
        return EXIT_LAUNCH;
    }

    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup);
    BOOL launched = CreateProcessW(executable, command, NULL, NULL, TRUE, 0,
                                   NULL, NULL, &startup, &process);
    free(command);
    if (!launched) {
        return EXIT_LAUNCH;
    }

    int ok = write_pid_path(pidfile, process.dwProcessId) &&
             write_text(GetStdHandle(STD_OUTPUT_HANDLE), "PARENT-OUT\n") &&
             write_text(GetStdHandle(STD_ERROR_HANDLE), "PARENT-ERR\n");
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return ok ? 0 : EXIT_PIDFILE;
}

static int stdin_echo(void) {
    HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    unsigned char buffer[16384];
    uint64_t total = 0;
    for (;;) {
        DWORD count = 0;
        if (!ReadFile(input, buffer, sizeof(buffer), &count, NULL)) {
            if (GetLastError() == ERROR_BROKEN_PIPE) {
                break;
            }
            return EXIT_OUTPUT;
        }
        if (count == 0) {
            break;
        }
        if (!write_all(output, buffer, count)) {
            return EXIT_OUTPUT;
        }
        total += count;
    }
    char summary[64];
    int length = snprintf(summary, sizeof(summary), "BYTES:%llu\n",
                          (unsigned long long)total);
    return length > 0 && write_all(GetStdHandle(STD_ERROR_HANDLE), summary,
                                   (DWORD)length)
               ? 0
               : EXIT_OUTPUT;
}

/* ConPTY starts in cooked console-input mode, so a newline terminates one
 * logical record. Count (rather than echo) the record to make a large `pty
 * send` verifiable without depending on terminal echo or output chunking. */
static int stdin_line_count(void) {
    HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    unsigned char buffer[16384];
    uint64_t total = 0;
    int complete = 0;
    while (!complete) {
        DWORD count = 0;
        if (!ReadFile(input, buffer, sizeof(buffer), &count, NULL) || count == 0) {
            return EXIT_OUTPUT;
        }
        for (DWORD index = 0; index < count; index++) {
            if (buffer[index] == '\r' || buffer[index] == '\n') {
                complete = 1;
                break;
            }
            total++;
        }
    }
    char summary[64];
    int length = snprintf(summary, sizeof(summary), "PTY-BYTES:%llu\n",
                          (unsigned long long)total);
    return length > 0 && write_all(GetStdHandle(STD_OUTPUT_HANDLE), summary,
                                   (DWORD)length)
               ? 0
               : EXIT_OUTPUT;
}

static int flood_capture(void) {
    enum { CHUNK = 16384, TOTAL = (1 << 20) + 8192 };
    unsigned char out[CHUNK];
    unsigned char err[CHUNK];
    memset(out, 'O', sizeof(out));
    memset(err, 'E', sizeof(err));
    for (int offset = 0; offset < TOTAL; offset += CHUNK) {
        DWORD count = (DWORD)((TOTAL - offset) < CHUNK ? TOTAL - offset : CHUNK);
        if (!write_all(GetStdHandle(STD_OUTPUT_HANDLE), out, count)) {
            return EXIT_OUTPUT;
        }
    }
    for (int offset = 0; offset < TOTAL; offset += CHUNK) {
        DWORD count = (DWORD)((TOTAL - offset) < CHUNK ? TOTAL - offset : CHUNK);
        if (!write_all(GetStdHandle(STD_ERROR_HANDLE), err, count)) {
            return EXIT_OUTPUT;
        }
    }
    return 0;
}

static int daemon_marker(const wchar_t *path, DWORD delay_ms) {
    Sleep(delay_ms);
    return write_pid_path(path, GetCurrentProcessId()) ? 0 : EXIT_PIDFILE;
}

/* Environment entries normally split at their first '='. The hidden per-drive
 * current-directory entries use =C:=C:\path, whose name is =C:. */
static size_t environment_name_length(const wchar_t *entry) {
    size_t length = entry[0] == L'=' ? 1 : 0;
    while (entry[length] != L'\0' && entry[length] != L'=') {
        length++;
    }
    return length;
}

/* Verify the child's complete environment block is in Windows' required
 * case-insensitive Unicode ordinal order, then print requested entries in the
 * order in which they actually occur. This observes the block passed to
 * CreateProcess rather than relying on lookup APIs, which hide its ordering. */
static int environment_order(int key_count, wchar_t **keys) {
    unsigned char *seen = (unsigned char *)calloc((size_t)key_count, 1);
    LPWCH block = GetEnvironmentStringsW();
    if (seen == NULL || block == NULL) {
        free(seen);
        if (block != NULL) {
            FreeEnvironmentStringsW(block);
        }
        return EXIT_ENVIRONMENT;
    }

    const wchar_t *previous = NULL;
    size_t previous_length = 0;
    int result = 0;
    for (const wchar_t *entry = block; *entry != L'\0'; entry += wcslen(entry) + 1) {
        size_t name_length = environment_name_length(entry);
        if (name_length > INT_MAX) {
            result = EXIT_ENVIRONMENT;
            break;
        }
        if (previous != NULL) {
            int comparison = CompareStringOrdinal(previous, (int)previous_length,
                                                  entry, (int)name_length, TRUE);
            if (comparison == 0 || comparison == CSTR_GREATER_THAN) {
                result = EXIT_ENVIRONMENT;
                break;
            }
        }

        for (int index = 0; index < key_count; index++) {
            size_t key_length = wcslen(keys[index]);
            if (key_length > INT_MAX) {
                result = EXIT_ENVIRONMENT;
                break;
            }
            int comparison = CompareStringOrdinal(entry, (int)name_length,
                                                  keys[index], (int)key_length, TRUE);
            if (comparison == 0) {
                result = EXIT_ENVIRONMENT;
                break;
            }
            if (comparison == CSTR_EQUAL) {
                if (seen[index]) {
                    result = EXIT_ENVIRONMENT;
                    break;
                }
                DWORD utf8_length = 0;
                char *utf8 = utf8_from_wide(entry, &utf8_length);
                if (utf8 == NULL || !write_all(GetStdHandle(STD_OUTPUT_HANDLE),
                                               utf8, utf8_length) ||
                    !write_text(GetStdHandle(STD_OUTPUT_HANDLE), "\n")) {
                    free(utf8);
                    result = EXIT_OUTPUT;
                    break;
                }
                free(utf8);
                seen[index] = 1;
            }
        }
        if (result != 0) {
            break;
        }
        previous = entry;
        previous_length = name_length;
    }

    if (result == 0) {
        for (int index = 0; index < key_count; index++) {
            if (!seen[index]) {
                result = EXIT_ENVIRONMENT;
                break;
            }
        }
    }
    FreeEnvironmentStringsW(block);
    free(seen);
    return result;
}

int wmain(int argc, wchar_t **argv) {
    if (argc < 2 || !write_environment_pidfile()) {
        return argc < 2 ? EXIT_USAGE : EXIT_PIDFILE;
    }

    if (wcscmp(argv[1], L"ok") == 0 || wcscmp(argv[1], L"fail") == 0) {
        if (argc != 3) {
            return EXIT_USAGE;
        }
        DWORD payload_length = 0;
        char *payload = utf8_from_wide(argv[2], &payload_length);
        if (payload == NULL) {
            return EXIT_ENCODING;
        }
        int ok = write_all(GetStdHandle(STD_OUTPUT_HANDLE), payload, payload_length) &&
                 write_text(GetStdHandle(STD_ERROR_HANDLE), "E:") &&
                 write_all(GetStdHandle(STD_ERROR_HANDLE), payload, payload_length);
        free(payload);
        return ok ? (wcscmp(argv[1], L"ok") == 0 ? 0 : 7) : EXIT_OUTPUT;
    }

    if (wcscmp(argv[1], L"hang") == 0 && argc == 3) {
        DWORD delay = milliseconds(argv[2]);
        if (delay == UINT32_MAX) {
            return EXIT_USAGE;
        }
        Sleep(delay);
        return 0;
    }
    if (wcscmp(argv[1], L"descendant-child") == 0 && argc == 3) {
        DWORD delay = milliseconds(argv[2]);
        return delay == UINT32_MAX ? EXIT_USAGE : descendant_child(delay);
    }
    if (wcscmp(argv[1], L"descendant-parent") == 0 && argc == 4) {
        DWORD delay = milliseconds(argv[2]);
        return delay == UINT32_MAX ? EXIT_USAGE
                                   : descendant_parent(delay, argv[3]);
    }
    if (wcscmp(argv[1], L"stdin-echo") == 0 && argc == 2) {
        return stdin_echo();
    }
    if (wcscmp(argv[1], L"stdin-line-count") == 0 && argc == 2) {
        return stdin_line_count();
    }
    if (wcscmp(argv[1], L"flood-capture") == 0 && argc == 2) {
        return flood_capture();
    }
    if (wcscmp(argv[1], L"daemon-marker") == 0 && argc == 4) {
        DWORD delay = milliseconds(argv[3]);
        return delay == UINT32_MAX ? EXIT_USAGE
                                   : daemon_marker(argv[2], delay);
    }
    if (wcscmp(argv[1], L"environment-order") == 0 && argc >= 3) {
        return environment_order(argc - 2, argv + 2);
    }
    return EXIT_USAGE;
}
