#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int write_ready(const wchar_t *path) {
    FILE *file = _wfopen(path, L"wb");
    if (file == NULL) {
        return 0;
    }
    int ok = fprintf(file, "ready\n") > 0 && fflush(file) == 0;
    return fclose(file) == 0 && ok;
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: sqlite_lock_fixture DB READY-FILE HOLD-MS\n");
        return 64;
    }
    wchar_t *end = NULL;
    unsigned long hold = wcstoul(argv[3], &end, 10);
    if (end == argv[3] || *end != L'\0' || hold > UINT32_MAX) {
        return 64;
    }

    sqlite3 *database = NULL;
    if (sqlite3_open16(argv[1], &database) != SQLITE_OK) {
        fprintf(stderr, "sqlite open failed: %s\n", sqlite3_errmsg(database));
        sqlite3_close(database);
        return 65;
    }
    char *message = NULL;
    if (sqlite3_exec(database, "BEGIN EXCLUSIVE", NULL, NULL, &message) != SQLITE_OK) {
        fprintf(stderr, "exclusive lock failed: %s\n", message != NULL ? message : "unknown");
        sqlite3_free(message);
        sqlite3_close(database);
        return 66;
    }
    if (!write_ready(argv[2])) {
        sqlite3_exec(database, "ROLLBACK", NULL, NULL, NULL);
        sqlite3_close(database);
        return 67;
    }
    Sleep((DWORD)hold);
    int ok = sqlite3_exec(database, "COMMIT", NULL, NULL, &message) == SQLITE_OK;
    if (!ok) {
        fprintf(stderr, "commit failed: %s\n", message != NULL ? message : "unknown");
    }
    sqlite3_free(message);
    sqlite3_close(database);
    return ok ? 0 : 68;
}
