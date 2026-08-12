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

    char headers[512];
    int header_length = snprintf(headers, sizeof(headers),
        "HTTP/1.1 %d %s\r\nContent-Length: %d\r\n"
        "Content-Type: application/octet-stream\r\n"
        "X-Machteld-Fixture: local\r\nConnection: close\r\n\r\n",
        status, status == 200 ? "OK" : "Not Found", response_length);
    int ok = header_length > 0 && send_all(client, headers, header_length) &&
             send_all(client, response_body, response_length);
    if (strcmp(path, "/slow") == 0) ok = 1;
    free(large);
    free(request);
    return ok;
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: http_fixture PORT-FILE REQUEST-COUNT\n");
        return 64;
    }
    wchar_t *end = NULL;
    unsigned long request_count = wcstoul(argv[2], &end, 10);
    if (end == argv[2] || *end != L'\0' || request_count == 0 || request_count > 100) {
        return 64;
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
