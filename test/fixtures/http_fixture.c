#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int send_all(SOCKET socket, const char *bytes, int length) {
    int offset = 0;
    while (offset < length) {
        int count = send(socket, bytes + offset, length - offset, 0);
        if (count <= 0) return 0;
        offset += count;
    }
    return 1;
}

static int write_port(const wchar_t *path, unsigned short port) {
    HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    char text[16];
    int length = snprintf(text, sizeof(text), "%hu", port);
    DWORD written = 0;
    int ok = length > 0 && WriteFile(file, text, (DWORD)length, &written, NULL) &&
             written == (DWORD)length && FlushFileBuffers(file);
    CloseHandle(file);
    return ok;
}

static int content_length(const char *headers) {
    const char *cursor = headers;
    while (*cursor != '\0') {
        const char *end = strstr(cursor, "\r\n");
        if (end == NULL || end == cursor) break;
        if ((size_t)(end - cursor) > 15 &&
            _strnicmp(cursor, "Content-Length:", 15) == 0) {
            while (cursor + 15 < end && isspace((unsigned char)cursor[15])) cursor++;
            return atoi(cursor + 15);
        }
        cursor = end + 2;
    }
    return 0;
}

static int header_equals(const char *headers, const char *name, const char *value) {
    size_t name_length = strlen(name);
    const char *cursor = strstr(headers, "\r\n");
    if (cursor == NULL) return 0;
    cursor += 2;
    while (*cursor != '\0') {
        const char *end = strstr(cursor, "\r\n");
        if (end == NULL || end == cursor) break;
        if ((size_t)(end - cursor) > name_length &&
            _strnicmp(cursor, name, name_length) == 0 && cursor[name_length] == ':') {
            const char *found = cursor + name_length + 1;
            while (found < end && (*found == ' ' || *found == '\t')) found++;
            return (size_t)(end - found) == strlen(value) &&
                   _strnicmp(found, value, strlen(value)) == 0;
        }
        cursor = end + 2;
    }
    return 0;
}

/* The absolute redirect target for /redir/NNN/abs, from argv (empty = the
 * endpoint answers 404). Set once in wmain before any client is served. */
static char g_abs_location[512];

static int serve_one(SOCKET client) {
    enum { CAPACITY = 1024 * 1024 };
    char *request = (char *)calloc(CAPACITY + 1, 1);
    if (request == NULL) return 0;
    int used = 0;
    char *body = NULL;
    int wanted = 0;
    while (used < CAPACITY) {
        int count = recv(client, request + used, CAPACITY - used, 0);
        if (count <= 0) break;
        used += count;
        request[used] = '\0';
        if (body == NULL) {
            body = strstr(request, "\r\n\r\n");
            if (body != NULL) {
                body += 4;
                wanted = content_length(request);
            }
        }
        if (body != NULL && used - (int)(body - request) >= wanted) break;
    }
    if (body == NULL) {
        free(request);
        return 0;
    }

    char method[16] = {0};
    char path[256] = {0};
    if (sscanf(request, "%15s %255s", method, path) != 2) {
        free(request);
        return 0;
    }
    const char *response_body = "not found";
    int response_length = 9;
    int status = 404;
    char *large = NULL;
    if (strcmp(path, "/ok") == 0) {
        response_body = "LOCAL-OK";
        response_length = 8;
        status = 200;
    } else if (strcmp(path, "/echo") == 0 && strcmp(method, "POST") == 0) {
        response_body = body;
        response_length = wanted;
        status = 200;
    } else if (strcmp(path, "/large") == 0) {
        response_length = 4096;
        large = (char *)malloc((size_t)response_length);
        if (large == NULL) {
            free(request);
            return 0;
        }
        memset(large, 'A', (size_t)response_length);
        response_body = large;
        status = 200;
    } else if (strcmp(path, "/type") == 0 &&
               header_equals(request, "Content-Type", "application/custom")) {
        response_body = "TYPE-OK";
        response_length = 7;
        status = 200;
    } else if (strcmp(path, "/slow") == 0) {
        Sleep(6000);
        response_body = "SLOW";
        response_length = 4;
        status = 200;
    }

    /* 3xx endpoints for the redirect canary (plan-machteld-015 H1/H2):
     * /redir/NNN/rel answers NNN with a relative Location (/ok);
     * /redir/NNN/abs answers NNN with the absolute target from argv. */
    char location[600] = "";
    if (strncmp(path, "/redir/", 7) == 0 && strlen(path) == 14 &&
        (strcmp(path + 10, "/rel") == 0 || strcmp(path + 10, "/abs") == 0)) {
        int code = atoi(path + 7);
        if (code == 301 || code == 302 || code == 303 ||
            code == 307 || code == 308) {
            if (path[11] == 'r') {
                snprintf(location, sizeof(location), "Location: /ok\r\n");
                status = code;
            } else if (g_abs_location[0] != '\0') {
                snprintf(location, sizeof(location), "Location: %s\r\n",
                         g_abs_location);
                status = code;
            }
            if (status == code) {
                response_body = "REDIRECTED";
                response_length = 10;
            }
        }
    }

    char headers[1200];
    int header_length = snprintf(headers, sizeof(headers),
        "HTTP/1.1 %d %s\r\nContent-Length: %d\r\n"
        "Content-Type: application/octet-stream\r\n%s"
        "X-Machteld-Fixture: local\r\nConnection: close\r\n\r\n",
        status, status == 200 ? "OK" :
                (status >= 300 && status < 400 ? "Redirect" : "Not Found"),
        response_length, location);
    int ok = header_length > 0 && send_all(client, headers, header_length) &&
             send_all(client, response_body, response_length);
    if (strcmp(path, "/slow") == 0) ok = 1;
    free(large);
    free(request);
    return ok;
}

int wmain(int argc, wchar_t **argv) {
    /* Two modes (plan-machteld-015 H1):
     *   http_fixture PORT-FILE REQUEST-COUNT ?ABS-LOCATION?
     *     - the classic exact-count server; ABS-LOCATION arms the
     *       /redir/NNN/abs endpoints.
     *   http_fixture PORT-FILE -canary HIT-FILE SECONDS
     *     - the zero-request target: listens for SECONDS; ANY accepted
     *       connection writes HIT-FILE (and is answered 200). Exit 0
     *       either way - the TEST asserts the hit file's absence, which
     *       is how a negative becomes provable. */
    int canary = (argc == 5 && wcscmp(argv[2], L"-canary") == 0);
    if (!canary && argc != 3 && argc != 4) {
        fprintf(stderr, "usage: http_fixture PORT-FILE REQUEST-COUNT ?ABS-LOCATION?\n"
                        "       http_fixture PORT-FILE -canary HIT-FILE SECONDS\n");
        return 64;
    }
    unsigned long request_count = 0;
    unsigned long canary_seconds = 0;
    if (canary) {
        wchar_t *end = NULL;
        canary_seconds = wcstoul(argv[4], &end, 10);
        if (end == argv[4] || *end != L'\0' ||
            canary_seconds == 0 || canary_seconds > 60) {
            return 64;
        }
    } else {
        wchar_t *end = NULL;
        request_count = wcstoul(argv[2], &end, 10);
        if (end == argv[2] || *end != L'\0' || request_count == 0 || request_count > 100) {
            return 64;
        }
        if (argc == 4) {
            snprintf(g_abs_location, sizeof(g_abs_location), "%ls", argv[3]);
        }
    }

    WSADATA winsock;
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) return 65;
    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) {
        WSACleanup();
        return 66;
    }
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) == SOCKET_ERROR ||
        listen(listener, 8) == SOCKET_ERROR) {
        closesocket(listener);
        WSACleanup();
        return 67;
    }
    int address_length = sizeof(address);
    if (getsockname(listener, (struct sockaddr *)&address, &address_length) == SOCKET_ERROR ||
        !write_port(argv[1], ntohs(address.sin_port))) {
        closesocket(listener);
        WSACleanup();
        return 68;
    }

    if (canary) {
        ULONGLONG deadline = GetTickCount64() + canary_seconds * 1000ull;
        for (;;) {
            ULONGLONG now = GetTickCount64();
            if (now >= deadline) break;
            fd_set readable;
            FD_ZERO(&readable);
            FD_SET(listener, &readable);
            struct timeval tv;
            ULONGLONG left = deadline - now;
            tv.tv_sec = (long)(left / 1000);
            tv.tv_usec = (long)((left % 1000) * 1000);
            int ready = select(0, &readable, NULL, NULL, &tv);
            if (ready <= 0) break;
            SOCKET client = accept(listener, NULL, NULL);
            if (client == INVALID_SOCKET) break;
            HANDLE hit = CreateFileW(argv[3], GENERIC_WRITE, 0, NULL,
                                     CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
            if (hit != INVALID_HANDLE_VALUE) {
                DWORD written = 0;
                WriteFile(hit, "HIT", 3, &written, NULL);
                CloseHandle(hit);
            }
            serve_one(client);
            shutdown(client, SD_BOTH);
            closesocket(client);
        }
        closesocket(listener);
        WSACleanup();
        return 0;
    }

    int ok = 1;
    for (unsigned long i = 0; i < request_count; i++) {
        SOCKET client = accept(listener, NULL, NULL);
        if (client == INVALID_SOCKET) { ok = 0; break; }
        if (!serve_one(client)) ok = 0;
        shutdown(client, SD_BOTH);
        closesocket(client);
        if (!ok) break;
    }
    closesocket(listener);
    WSACleanup();
    return ok ? 0 : 69;
}
