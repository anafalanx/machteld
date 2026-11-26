/* Immutable application generations. A named read-only section pins one
 * delete-on-close snapshot while any member of the generation is running. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <fcntl.h>
#include "machteld.h"

#define BUFFER_MOUNT_MAX (64u * 1024u * 1024u)
#define MOUNT "machteld-app"
#define TOKEN_CHARS 32

typedef struct {
    HANDLE section;
    HANDLE backing;
    void *view;
    size_t size;
    char token[TOKEN_CHARS + 1];
    char expected_sha256[65];
    BY_HANDLE_FILE_INFORMATION file;
} Generation;

/* Retained until process teardown, including while a user exit handler runs.
 * The OS releases the mapping and removes its backing file on abnormal exit. */
static Generation current;
static HANDLE mount_source = INVALID_HANDLE_VALUE;
static DWORD mount_open_error;

static int
os_error(Tcl_Interp *interp, const char *operation, DWORD code)
{
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s (Windows error %lu)",
        operation, (unsigned long)code));
    Tcl_SetErrorCode(interp, "MACHTELD", "ENTRY", "oserror", NULL);
    return TCL_ERROR;
}

static int
mount_error(Tcl_Interp *interp)
{
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("cannot mount .machteld archive: %s",
        Tcl_GetStringResult(interp)));
    Tcl_SetErrorCode(interp, "MACHTELD", "ENTRY", "badvalue", NULL);
    return TCL_ERROR;
}

static int
snapshot_path(Tcl_Obj *path, void **unused)
{
    (void)unused;
    return strcmp(Tcl_GetString(path), MACHTELD_SNAPSHOT_PATH) == 0 ? TCL_OK : -1;
}

static Tcl_Obj *
snapshot_separator(Tcl_Obj *unused)
{
    (void)unused;
    return Tcl_NewStringObj("/", 1);
}

static Tcl_Channel
snapshot_open(Tcl_Interp *interp, Tcl_Obj *path, int mode, int permissions)
{
    (void)path; (void)permissions;
    HANDLE handle;
    if ((mode & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) != 0 ||
            !DuplicateHandle(GetCurrentProcess(), mount_source,
                GetCurrentProcess(), &handle, GENERIC_READ, FALSE, 0)) {
        mount_open_error = GetLastError();
        if (interp != NULL) os_error(interp, "cannot open the archive snapshot", mount_open_error);
        return NULL;
    }
    Tcl_Channel chan = Tcl_MakeFileChannel(handle, TCL_READABLE);
    if (chan == NULL) {
        mount_open_error = ERROR_OPEN_FAILED;
        CloseHandle(handle);
    }
    return chan;
}

/* MountBuffer has a 64 MiB ceiling. For larger archives, give Tcl's own
 * file mapper a read-only handle without reopening a delete-on-close file
 * using its default share flags. This exact-path adapter is removed before
 * evaluating application code. */
static const Tcl_Filesystem snapshot_fs = {
    .typeName = "machteld-snapshot",
    .structureLength = sizeof(Tcl_Filesystem),
    .version = TCL_FILESYSTEM_VERSION_1,
    .pathInFilesystemProc = snapshot_path,
    .filesystemSeparatorProc = snapshot_separator,
    .openFileChannelProc = snapshot_open
};

int
Machteld_MountPinnedFile(Tcl_Interp *interp, void *file, const char *mount)
{
    if (Tcl_FSRegister(NULL, &snapshot_fs) != TCL_OK) {
        return interp == NULL ? TCL_ERROR :
            Machteld_EntryError(interp, "state", "cannot register the archive reader");
    }
    mount_source = file;
    mount_open_error = ERROR_SUCCESS;
    int status = TclZipfs_Mount(interp, MACHTELD_SNAPSHOT_PATH, mount, NULL);
    if (status != TCL_OK && interp != NULL) {
        status = mount_open_error == ERROR_SUCCESS ? mount_error(interp) :
            os_error(interp, "cannot open the archive snapshot", mount_open_error);
    }
    mount_source = INVALID_HANDLE_VALUE;
    Tcl_FSUnregister(&snapshot_fs);
    return status;
}

static int
new_token(Tcl_Interp *interp, char token[TOKEN_CHARS + 1])
{
    static const char digits[] = "0123456789abcdef";
    unsigned char entropy[TOKEN_CHARS / 2];
    if (BCryptGenRandom(NULL, entropy, sizeof entropy,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
        return Machteld_EntryError(interp, "oserror", "cannot name an archive generation");
    }
    for (size_t i = 0; i < sizeof entropy; i++) {
        token[2*i] = digits[entropy[i] >> 4];
        token[2*i+1] = digits[entropy[i] & 15];
    }
    token[TOKEN_CHARS] = '\0';
    return TCL_OK;
}

static void
section_name(char name[64], const char *token)
{
    snprintf(name, 64, "Local\\MachteldArchive-%s", token);
}

static wchar_t *
temp_name(const char *token)
{
    /* GetTempPathW may return a path longer than MAX_PATH. Tcl's temp
     * directory and cwd are not application state for this private file. */
    DWORD need = GetTempPathW(0, NULL);
    if (need == 0 || need > 32767) return NULL;
    size_t capacity = (size_t)need + 64;
    wchar_t *path = malloc(capacity * sizeof(*path));
    if (path == NULL) { SetLastError(ERROR_OUTOFMEMORY); return NULL; }
    DWORD got = GetTempPathW(need, path);
    if (got == 0 || got >= need) { free(path); return NULL; }
    swprintf(path + got, capacity - got, L"machteld-archive-%hs.tmp", token);
    return path;
}

static HANDLE
open_temp(const char *token, int create)
{
    wchar_t *name = temp_name(token);
    if (name == NULL) return INVALID_HANDLE_VALUE;
    HANDLE file = CreateFileW(name, create ? GENERIC_READ | GENERIC_WRITE | DELETE : GENERIC_READ,
        create ? FILE_SHARE_READ | FILE_SHARE_DELETE :
                 FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
        create ? CREATE_NEW : OPEN_EXISTING,
        create ? FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE :
                 FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    DWORD error = GetLastError();
    free(name);
    SetLastError(error);
    return file;
}

static int
copy_snapshot(Tcl_Interp *interp, HANDLE from, const unsigned char *memory,
              size_t size, HANDLE to)
{
    unsigned char buffer[64 * 1024];
    for (size_t pos = 0; pos < size;) {
        size_t remaining = size - pos;
        DWORD want = remaining < sizeof buffer ? (DWORD)remaining : (DWORD)sizeof buffer;
        DWORD got = want, wrote;
        const unsigned char *data;
        if (memory != NULL) {
            data = memory + pos;
        } else {
            if (!ReadFile(from, buffer, want, &got, NULL)) {
                return os_error(interp, "cannot read the application archive", GetLastError());
            }
            if (got == 0) return Machteld_EntryError(interp, "oserror", "unexpected end of application archive");
            data = buffer;
        }
        if (!WriteFile(to, data, got, &wrote, NULL) || wrote != got) {
            return os_error(interp, "cannot write the application snapshot", GetLastError());
        }
        pos += got;
    }
    return TCL_OK;
}

static int
create_generation(Tcl_Interp *interp, Tcl_Obj *origin, HANDLE *backing)
{
    const wchar_t *native = Tcl_FSGetNativePath(origin);
    if (native == NULL) return Machteld_EntryError(interp, "badvalue", "the archive must be a native file");
    /* A publisher can rename this generation, but cannot modify the bytes
     * in place while the snapshot is being taken. */
    HANDLE input = CreateFileW(native, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, NULL,
        OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (input == INVALID_HANDLE_VALUE) return os_error(interp, "cannot open the application archive", GetLastError());
    LARGE_INTEGER size;
    int status = TCL_ERROR;
    if (!GetFileSizeEx(input, &size)) {
        os_error(interp, "cannot size the application archive", GetLastError());
        goto done;
    }
    if (GetFileType(input) != FILE_TYPE_DISK || size.QuadPart < 0 ||
            (uint64_t)size.QuadPart > (uint64_t)TCL_SIZE_MAX) {
        Machteld_EntryError(interp, "badvalue", "the archive must be a regular file");
        goto done;
    }
    if (size.QuadPart == 0) {
        Machteld_EntryError(interp, "badvalue", "cannot mount .machteld archive: empty archive");
        goto done;
    }
    current.size = (size_t)size.QuadPart;
    if (new_token(interp, current.token) != TCL_OK) goto done;
    *backing = open_temp(current.token, 1);
    if (*backing == INVALID_HANDLE_VALUE) {
        os_error(interp, "cannot create the application snapshot", GetLastError());
        goto done;
    }
    if (copy_snapshot(interp, input, NULL, current.size, *backing) != TCL_OK) goto done;
    if (!GetFileInformationByHandle(*backing, &current.file)) {
        os_error(interp, "cannot identify the application snapshot", GetLastError());
        goto done;
    }
    char name[64];
    section_name(name, current.token);
    current.section = CreateFileMappingA(*backing, NULL, PAGE_READONLY, 0, 0, name);
    if (!current.section || GetLastError() == ERROR_ALREADY_EXISTS) {
        Machteld_EntryError(interp, "oserror", "cannot create a unique application generation");
        goto done;
    }
    status = TCL_OK;
done:
    CloseHandle(input);
    return status;
}

/* The file identity only accelerates mounting a large generation. Its
 * read-only named section remains the authority even if the temp directory
 * changed, a parent exited, or its old temporary name is unavailable. */
static int
reopen_generation(Tcl_Interp *interp, Tcl_Obj *ticket, HANDLE *backing)
{
    Tcl_Obj **fields;
    Tcl_Size count;
    Tcl_WideInt numbers[4];
    if (Tcl_ListObjGetElements(interp, ticket, &count, &fields) != TCL_OK || count != 6) goto invalid;
    Tcl_Size nchars;
    const char *token = Tcl_GetStringFromObj(fields[0], &nchars);
    if (nchars != TOKEN_CHARS || strspn(token, "0123456789abcdef") != TOKEN_CHARS) goto invalid;
    const char *expected = Tcl_GetStringFromObj(fields[5], &nchars);
    if (nchars != 64 || strspn(expected, "0123456789abcdef") != 64) goto invalid;
    memcpy(current.expected_sha256, expected, sizeof current.expected_sha256);
    for (int i = 0; i < 4; i++) {
        if (Tcl_GetWideIntFromObj(interp, fields[i+1], &numbers[i]) != TCL_OK ||
                numbers[i] < 0 || (i > 0 && numbers[i] > UINT32_MAX)) goto invalid;
    }
    if (numbers[0] == 0 || (uint64_t)numbers[0] > (uint64_t)TCL_SIZE_MAX) goto invalid;
    memcpy(current.token, token, TOKEN_CHARS+1);
    current.size = (size_t)numbers[0];
    current.file.dwVolumeSerialNumber = (DWORD)numbers[1];
    current.file.nFileIndexHigh = (DWORD)numbers[2];
    current.file.nFileIndexLow = (DWORD)numbers[3];
    char name[64];
    section_name(name, token);
    current.section = OpenFileMappingA(FILE_MAP_READ, FALSE, name);
    if (!current.section) {
        return Machteld_EntryError(interp, "notfound", "the application generation is no longer available");
    }
    if (current.size > BUFFER_MOUNT_MAX) {
        HANDLE file = open_temp(token, 0);
        if (file != INVALID_HANDLE_VALUE) {
            BY_HANDLE_FILE_INFORMATION facts;
            if (GetFileInformationByHandle(file, &facts) &&
                    facts.dwVolumeSerialNumber == current.file.dwVolumeSerialNumber &&
                    facts.nFileIndexHigh == current.file.nFileIndexHigh &&
                    facts.nFileIndexLow == current.file.nFileIndexLow &&
                    !(facts.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY))) {
                *backing = file;
            } else CloseHandle(file);
        }
    }
    return TCL_OK;
invalid:
    return Machteld_EntryError(interp, "badvalue", "invalid application generation");
}

int
Machteld_MountApp(Tcl_Interp *interp, Tcl_Obj *origin, Tcl_Obj *ticket, Tcl_Obj *prefix)
{
    HANDLE backing = INVALID_HANDLE_VALUE;
    int status = ticket == NULL ? create_generation(interp, origin, &backing) :
        reopen_generation(interp, ticket, &backing);
    if (status != TCL_OK) goto done;

    current.view = MapViewOfFile(current.section, FILE_MAP_READ, 0, 0, current.size);
    if (current.view == NULL) {
        status = os_error(interp, "cannot read the pinned application generation", GetLastError());
        goto done;
    }
    char sha256[65];
    status = Machteld_SnapshotSha256(interp, current.view, current.size, sha256);
    if (status != TCL_OK) goto done;
    if (ticket != NULL && strcmp(current.expected_sha256, sha256) != 0) {
        status = Machteld_EntryError(interp, "inventory", "application generation SHA-256 mismatch");
        goto done;
    }
    if (current.size <= BUFFER_MOUNT_MAX) {
        status = TclZipfs_MountBuffer(interp, current.view, current.size, MOUNT, 0);
        if (status != TCL_OK) status = mount_error(interp);
    } else {
        if (backing == INVALID_HANDLE_VALUE) {
            char name[TOKEN_CHARS + 1];
            if (new_token(interp, name) != TCL_OK) { status = TCL_ERROR; goto done; }
            backing = open_temp(name, 1);
            if (backing == INVALID_HANDLE_VALUE) {
                status = os_error(interp, "cannot create a large archive reader", GetLastError());
                goto done;
            }
            status = copy_snapshot(interp, INVALID_HANDLE_VALUE, current.view, current.size, backing);
            if (status != TCL_OK) goto done;
        }
        status = Machteld_MountPinnedFile(interp, backing, MOUNT);
        UnmapViewOfFile(current.view);
        current.view = NULL;
    }
    if (status == TCL_OK) {
        Tcl_Obj *fields[] = {
            Tcl_NewStringObj(current.token, -1), Tcl_NewWideIntObj((Tcl_WideInt)current.size),
            Tcl_NewWideIntObj(current.file.dwVolumeSerialNumber), Tcl_NewWideIntObj(current.file.nFileIndexHigh),
            Tcl_NewWideIntObj(current.file.nFileIndexLow), Tcl_NewStringObj(sha256, 64)
        };
        Tcl_ListObjAppendElement(interp, prefix, Tcl_NewStringObj("--machteld-generation", -1));
        Tcl_ListObjAppendElement(interp, prefix, origin);
        Tcl_ListObjAppendElement(interp, prefix, Tcl_NewListObj(6, fields));
    }
done:
    /* Keep the first temporary file reopenable while its creating process
     * lives. This avoids another copy when mounting a large archive worker. */
    if (backing != INVALID_HANDLE_VALUE) {
        if (status == TCL_OK && ticket == NULL) {
            current.backing = backing;
        } else CloseHandle(backing);
    }
    if (status != TCL_OK) {
        if (current.view) UnmapViewOfFile(current.view);
        if (current.section) CloseHandle(current.section);
        memset(&current, 0, sizeof current);
    }
    return status;
}
