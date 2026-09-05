/* Atomic publication of a completed file into a Windows namespace. */
#undef USE_TCL_STUBS
#include <tcl.h>

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>

#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef struct {
    Tcl_Obj *object;
    const wchar_t *name;
} NativePath;

typedef struct {
    FILE_ID_INFO extended;
    DWORD legacy_volume;
    ULONGLONG legacy_file;
    int has_extended;
    int has_legacy;
} PublishIdentity;

typedef struct {
    DWORD attributes;
    DWORD type;
    PublishIdentity identity;
} PublishFileInfo;

enum {
    PUBLISH_PROBE_ERROR = -1,
    PUBLISH_PROBE_ABSENT = 0,
    PUBLISH_PROBE_PRESENT = 1
};

static int
publish_error(Tcl_Interp *interp, const char *code, const char *message)
{
    Tcl_SetObjResult(interp, Tcl_NewStringObj(message, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", code, (char *)NULL);
    return TCL_ERROR;
}

static int
publish_win_error(Tcl_Interp *interp, const char *message, DWORD error,
                  const wchar_t *recovery)
{
    if (recovery == NULL) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(
            "%s (Windows error %lu)", message, (unsigned long)error));
    } else {
        Tcl_DString path;
        Tcl_DStringInit(&path);
        Tcl_WCharToUtfDString(recovery, -1, &path);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(
            "%s (Windows error %lu); the prior destination remains at %s",
            message, (unsigned long)error, Tcl_DStringValue(&path)));
        Tcl_DStringFree(&path);
    }
    Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "oserror", (char *)NULL);
    return TCL_ERROR;
}

static int
missing_error(DWORD error)
{
    return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
}

static int
exists_error(DWORD error)
{
    return error == ERROR_FILE_EXISTS || error == ERROR_ALREADY_EXISTS;
}

static void
native_path_release(NativePath *path)
{
    if (path->object != NULL) {
        Tcl_DecrRefCount(path->object);
    }
    path->object = NULL;
    path->name = NULL;
}

static int
native_path_from_obj(Tcl_Interp *interp, Tcl_Obj *value, const char *label,
                     NativePath *path)
{
    path->object = NULL;
    path->name = NULL;
    if (Tcl_GetCharLength(value) == 0) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s path must not be empty", label));
        Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "badvalue", (char *)NULL);
        return TCL_ERROR;
    }

    Tcl_Obj *normalized = Tcl_FSGetNormalizedPath(interp, value);
    if (normalized == NULL) {
        Tcl_ResetResult(interp);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s is not a usable path", label));
        Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "badvalue", (char *)NULL);
        return TCL_ERROR;
    }
    Tcl_IncrRefCount(normalized);
    const void *native = Tcl_FSGetNativePath(normalized);
    if (native == NULL) {
        Tcl_DecrRefCount(normalized);
        Tcl_ResetResult(interp);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(
            "%s must be on the native Windows filesystem", label));
        Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "badvalue", (char *)NULL);
        return TCL_ERROR;
    }
    path->object = normalized;
    path->name = (const wchar_t *)native;
    return TCL_OK;
}

static int
native_parent(Tcl_Interp *interp, const NativePath *child, const char *label,
              NativePath *parent)
{
    parent->object = NULL;
    parent->name = NULL;
    Tcl_Size part_count;
    Tcl_Obj *parts = Tcl_FSSplitPath(child->object, &part_count);
    if (parts == NULL || part_count < 2) {
        if (parts != NULL) {
            Tcl_IncrRefCount(parts);
            Tcl_DecrRefCount(parts);
        }
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(
            "%s has no publishable parent directory", label));
        Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "badvalue", (char *)NULL);
        return TCL_ERROR;
    }
    Tcl_IncrRefCount(parts);
    Tcl_Obj *joined = Tcl_FSJoinPath(parts, part_count - 1);
    if (joined != NULL) {
        Tcl_IncrRefCount(joined);
    }
    Tcl_DecrRefCount(parts);
    if (joined == NULL) {
        return publish_error(interp, "badvalue",
            "cannot resolve the publication parent directory");
    }
    const void *native = Tcl_FSGetNativePath(joined);
    if (native == NULL) {
        Tcl_DecrRefCount(joined);
        return publish_error(interp, "badvalue",
            "the publication parent must be on the native Windows filesystem");
    }
    parent->object = joined;
    parent->name = (const wchar_t *)native;
    return TCL_OK;
}

static int
query_handle(HANDLE handle, PublishFileInfo *info, DWORD *error)
{
    memset(info, 0, sizeof(*info));
    info->type = GetFileType(handle);
    BY_HANDLE_FILE_INFORMATION legacy;
    int has_legacy_info = GetFileInformationByHandle(handle, &legacy) != 0;
    if (has_legacy_info) {
        info->attributes = legacy.dwFileAttributes;
        info->identity.legacy_volume = legacy.dwVolumeSerialNumber;
        info->identity.legacy_file =
            ((ULONGLONG)legacy.nFileIndexHigh << 32) | legacy.nFileIndexLow;
        info->identity.has_legacy = 1;
    }

    FILE_ATTRIBUTE_TAG_INFO attributes;
    if (GetFileInformationByHandleEx(handle, FileAttributeTagInfo,
            &attributes, sizeof attributes)) {
        info->attributes = attributes.FileAttributes;
    } else if (!has_legacy_info) {
        *error = GetLastError();
        return 0;
    }

#ifndef MACHTELD_PUBLISH_FORCE_LEGACY_ID
    if (GetFileInformationByHandleEx(handle, FileIdInfo,
            &info->identity.extended, sizeof info->identity.extended)) {
        info->identity.has_extended = 1;
    }
#endif
    if (!info->identity.has_legacy && !info->identity.has_extended) {
        *error = GetLastError();
        return 0;
    }
    *error = ERROR_SUCCESS;
    return 1;
}

static int
probe_path(const wchar_t *path, DWORD access, DWORD sharing,
           PublishFileInfo *info, DWORD *error)
{
    HANDLE handle = CreateFileW(path, access, sharing, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (handle == INVALID_HANDLE_VALUE) {
        *error = GetLastError();
        return missing_error(*error) ? PUBLISH_PROBE_ABSENT : PUBLISH_PROBE_ERROR;
    }
    if (!query_handle(handle, info, error)) {
        CloseHandle(handle);
        return PUBLISH_PROBE_ERROR;
    }
    CloseHandle(handle);
    return PUBLISH_PROBE_PRESENT;
}

static int
same_identity_value(const PublishIdentity *left, const PublishIdentity *right)
{
    if (left->has_extended && right->has_extended) {
        return left->extended.VolumeSerialNumber ==
                   right->extended.VolumeSerialNumber &&
               memcmp(left->extended.FileId.Identifier,
                      right->extended.FileId.Identifier,
                      sizeof left->extended.FileId.Identifier) == 0;
    }
    return left->has_legacy && right->has_legacy &&
           left->legacy_volume == right->legacy_volume &&
           left->legacy_file == right->legacy_file;
}

static int
same_volume(const PublishIdentity *left, const PublishIdentity *right)
{
    if (left->has_extended && right->has_extended) {
        return left->extended.VolumeSerialNumber ==
               right->extended.VolumeSerialNumber;
    }
    return left->has_legacy && right->has_legacy &&
           left->legacy_volume == right->legacy_volume;
}

static int
same_identity(const PublishFileInfo *left, const PublishFileInfo *right)
{
    return same_identity_value(&left->identity, &right->identity);
}

static int
is_regular(const PublishFileInfo *info)
{
    return info->type == FILE_TYPE_DISK &&
           (info->attributes & (FILE_ATTRIBUTE_DIRECTORY |
                                FILE_ATTRIBUTE_REPARSE_POINT)) == 0;
}

static int
is_plain_directory(const PublishFileInfo *info)
{
    return info->type == FILE_TYPE_DISK &&
           (info->attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
           (info->attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
}

static int
check_parent(Tcl_Interp *interp, const NativePath *parent, const char *label,
             PublishFileInfo *info)
{
    DWORD error;
    int state = probe_path(parent->name, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, info, &error);
    if (state == PUBLISH_PROBE_ABSENT) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s does not exist", label));
        Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "badvalue", (char *)NULL);
        return TCL_ERROR;
    }
    if (state == PUBLISH_PROBE_ERROR) {
        return publish_win_error(interp,
            "cannot inspect the publication parent directory", error, NULL);
    }
    if (!is_plain_directory(info)) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(
            "%s must be a directory and not a reparse point", label));
        Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "badvalue", (char *)NULL);
        return TCL_ERROR;
    }
    return TCL_OK;
}

static int
check_candidate(Tcl_Interp *interp, const NativePath *candidate,
                const PublishFileInfo *expected, PublishFileInfo *current)
{
    DWORD error;
    int state = probe_path(candidate->name, FILE_READ_ATTRIBUTES | DELETE,
        FILE_SHARE_READ | FILE_SHARE_DELETE, current, &error);
    if (state == PUBLISH_PROBE_ABSENT) {
        return publish_error(interp, "badvalue",
            "publication candidate does not exist");
    }
    if (state == PUBLISH_PROBE_ERROR) {
        if (error == ERROR_SHARING_VIOLATION) {
            return publish_error(interp, "badvalue",
                "publication candidate is still open for writing");
        }
        return publish_win_error(interp,
            "cannot inspect the publication candidate", error, NULL);
    }
    if (!is_regular(current)) {
        return publish_error(interp, "badvalue",
            "publication candidate must be a regular file and not a reparse point");
    }
    if (expected != NULL && !same_identity(expected, current)) {
        return publish_error(interp, "badvalue",
            "publication candidate changed during publication");
    }
    return TCL_OK;
}

static int
check_destination(Tcl_Interp *interp, const NativePath *destination,
                  PublishFileInfo *info, DWORD *error)
{
    int state = probe_path(destination->name, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, info, error);
    if (state == PUBLISH_PROBE_ERROR) {
        publish_win_error(interp,
            "cannot inspect the publication destination", *error, NULL);
        return PUBLISH_PROBE_ERROR;
    }
    if (state == PUBLISH_PROBE_PRESENT && !is_regular(info)) {
        publish_error(interp, "badvalue",
            "publication destination must be a regular file and not a reparse point");
        return PUBLISH_PROBE_ERROR;
    }
    return state;
}

static wchar_t *
backup_marker(Tcl_Interp *interp, const NativePath *parent,
              PublishFileInfo *marker)
{
    static const wchar_t digits[] = L"0123456789abcdef";
    const wchar_t prefix[] = L".machteld-publish-backup-";
    size_t parent_length = wcslen(parent->name);
    int separator = parent_length != 0 &&
                    parent->name[parent_length - 1] != L'\\' &&
                    parent->name[parent_length - 1] != L'/';

    for (int attempt = 0; attempt < 16; attempt++) {
        unsigned char random[16];
        if (BCryptGenRandom(NULL, random, (ULONG)sizeof random,
                BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
            publish_error(interp, "oserror",
                "the system random generator failed while publishing");
            return NULL;
        }
        size_t prefix_length = (sizeof prefix / sizeof prefix[0]) - 1;
        size_t total = parent_length + (size_t)separator + prefix_length + 32;
        wchar_t *path = (wchar_t *)malloc((total + 1) * sizeof(wchar_t));
        if (path == NULL) {
            publish_error(interp, "oserror",
                "out of memory creating the publication backup path");
            return NULL;
        }
        memcpy(path, parent->name, parent_length * sizeof(wchar_t));
        size_t offset = parent_length;
        if (separator) {
            path[offset++] = L'\\';
        }
        memcpy(path + offset, prefix, prefix_length * sizeof(wchar_t));
        offset += prefix_length;
        for (size_t i = 0; i < sizeof random; i++) {
            path[offset++] = digits[random[i] >> 4];
            path[offset++] = digits[random[i] & 0x0f];
        }
        path[offset] = L'\0';

        HANDLE handle = CreateFileW(path,
            FILE_READ_ATTRIBUTES | GENERIC_WRITE | DELETE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            NULL, CREATE_NEW, FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_TEMPORARY,
            NULL);
        if (handle == INVALID_HANDLE_VALUE) {
            DWORD error = GetLastError();
            free(path);
            if (exists_error(error)) {
                continue;
            }
            publish_win_error(interp,
                "cannot reserve the publication backup path", error, NULL);
            return NULL;
        }

        DWORD error;
        if (!query_handle(handle, marker, &error)) {
            CloseHandle(handle);
            DeleteFileW(path);
            free(path);
            publish_win_error(interp,
                "cannot identify the publication backup marker", error, NULL);
            return NULL;
        }
        CloseHandle(handle);
        return path;
    }
    publish_error(interp, "oserror",
        "cannot reserve a unique publication backup path");
    return NULL;
}

static int
delete_open_handle(HANDLE handle, DWORD *error)
{
    PublishFileInfo current;
    if (!query_handle(handle, &current, error)) {
        return 0;
    }
    if (!is_regular(&current)) {
        *error = ERROR_DIRECTORY;
        return 0;
    }
    if ((current.attributes & FILE_ATTRIBUTE_READONLY) != 0) {
        FILE_BASIC_INFO basic;
        if (!GetFileInformationByHandleEx(handle, FileBasicInfo,
                &basic, sizeof basic)) {
            *error = GetLastError();
            return 0;
        }
        basic.FileAttributes &= ~FILE_ATTRIBUTE_READONLY;
        if (basic.FileAttributes == 0) {
            basic.FileAttributes = FILE_ATTRIBUTE_NORMAL;
        }
        if (!SetFileInformationByHandle(handle, FileBasicInfo,
                &basic, sizeof basic)) {
            *error = GetLastError();
            return 0;
        }
    }
    FILE_DISPOSITION_INFO disposition;
    disposition.DeleteFile = TRUE;
    if (!SetFileInformationByHandle(handle, FileDispositionInfo,
            &disposition, sizeof disposition)) {
        *error = GetLastError();
        return 0;
    }
    *error = ERROR_SUCCESS;
    return 1;
}

static int
delete_identity(const wchar_t *path, const PublishFileInfo *expected)
{
    HANDLE handle = CreateFileW(path,
        FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | DELETE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (handle == INVALID_HANDLE_VALUE) {
        return 0;
    }
    DWORD error;
    PublishFileInfo current;
    int removed = query_handle(handle, &current, &error) &&
                  is_regular(&current) && same_identity(&current, expected) &&
                  delete_open_handle(handle, &error);
    CloseHandle(handle);
    return removed;
}

static void
delete_backup_after_replace(HANDLE old_handle)
{
    DWORD error;
    /* Replacement has already committed.  Cleanup must not turn a successful
     * publication into an error whose documented preservation semantics are
     * no longer true.  A rare filesystem/sharing refusal therefore leaves the
     * randomly named recovery backup for manual cleanup. */
    (void)delete_open_handle(old_handle, &error);
}

/* Return nonzero when the old destination could only be retained at backup. */
static int
recover_replace_failure(HANDLE old_handle, const wchar_t *backup,
                        const wchar_t *destination,
                        const PublishFileInfo *marker)
{
    PublishFileInfo held;
    DWORD error;
    if (!query_handle(old_handle, &held, &error) || !is_regular(&held)) {
        return 1;
    }

    PublishFileInfo current;
    int state = probe_path(backup, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        &current, &error);
    if (state == PUBLISH_PROBE_ERROR) {
        return 1;
    }
    if (state == PUBLISH_PROBE_PRESENT) {
        if (!is_regular(&current)) {
            return 1;
        }
        if (same_identity(&current, &held)) {
            PublishFileInfo at_destination;
            state = probe_path(destination, FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                &at_destination, &error);
            if (state == PUBLISH_PROBE_ABSENT &&
                    MoveFileExW(backup, destination, 0)) {
                return 0;
            }
            return 1;
        }
        if (!same_identity(&current, marker)) {
            return 1;
        }
        delete_identity(backup, marker);
        state = probe_path(backup, FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            &current, &error);
        if (state != PUBLISH_PROBE_ABSENT) {
            return 1;
        }
    }

    PublishFileInfo at_destination;
    state = probe_path(destination, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        &at_destination, &error);
    if (state == PUBLISH_PROBE_PRESENT && is_regular(&at_destination) &&
            same_identity(&at_destination, &held)) {
        return 0;
    }
    return 1;
}

static int
PublishCmd(void *client_data, Tcl_Interp *interp, int objc,
           Tcl_Obj *const objv[])
{
    (void)client_data;
    if (objc != 3) {
        return publish_error(interp, "badvalue",
            "usage: ::machteld::Publish candidate destination");
    }

    int result = TCL_ERROR;
    NativePath candidate = {0};
    NativePath destination = {0};
    NativePath candidate_parent = {0};
    NativePath destination_parent = {0};
    if (native_path_from_obj(interp, objv[1], "publication candidate",
            &candidate) != TCL_OK ||
            native_path_from_obj(interp, objv[2], "publication destination",
            &destination) != TCL_OK ||
            native_parent(interp, &candidate, "publication candidate",
            &candidate_parent) != TCL_OK ||
            native_parent(interp, &destination, "publication destination",
            &destination_parent) != TCL_OK) {
        goto done;
    }

    PublishFileInfo original_candidate;
    if (check_candidate(interp, &candidate, NULL, &original_candidate) != TCL_OK) {
        goto done;
    }
    PublishFileInfo candidate_parent_info;
    PublishFileInfo destination_parent_info;
    if (check_parent(interp, &candidate_parent,
            "publication candidate parent", &candidate_parent_info) != TCL_OK ||
            check_parent(interp, &destination_parent,
            "publication destination parent", &destination_parent_info) != TCL_OK) {
        goto done;
    }
    if (!same_volume(&original_candidate.identity,
            &destination_parent_info.identity)) {
        publish_error(interp, "badvalue",
            "publication candidate and destination must be on the same volume");
        goto done;
    }

    for (int attempt = 0; attempt < 8; attempt++) {
        PublishFileInfo current_candidate;
        if (check_candidate(interp, &candidate, &original_candidate,
                &current_candidate) != TCL_OK) {
            goto done;
        }

        PublishFileInfo old_destination;
        DWORD probe_error;
        int state = check_destination(interp, &destination,
            &old_destination, &probe_error);
        if (state == PUBLISH_PROBE_ERROR) {
            goto done;
        }
        if (state == PUBLISH_PROBE_ABSENT) {
            if (MoveFileExW(candidate.name, destination.name, 0)) {
                Tcl_SetObjResult(interp, objv[2]);
                result = TCL_OK;
                goto done;
            }
            DWORD error = GetLastError();
            if (exists_error(error)) {
                continue;
            }
            publish_win_error(interp,
                "cannot publish the completed candidate", error, NULL);
            goto done;
        }

        if (same_identity(&current_candidate, &old_destination)) {
            publish_error(interp, "badvalue",
                "publication candidate and destination name the same file");
            goto done;
        }
        if (!same_volume(&old_destination.identity,
                &destination_parent_info.identity)) {
            publish_error(interp, "badvalue",
                "publication destination changed volumes during publication");
            goto done;
        }

        PublishFileInfo marker;
        wchar_t *backup = backup_marker(interp, &destination_parent, &marker);
        if (backup == NULL) {
            goto done;
        }

        PublishFileInfo final_candidate;
        if (check_candidate(interp, &candidate, &original_candidate,
                &final_candidate) != TCL_OK) {
            delete_identity(backup, &marker);
            free(backup);
            goto done;
        }
        PublishFileInfo final_destination;
        state = check_destination(interp, &destination,
            &final_destination, &probe_error);
        if (state == PUBLISH_PROBE_ERROR) {
            delete_identity(backup, &marker);
            free(backup);
            goto done;
        }
        if (state != PUBLISH_PROBE_PRESENT ||
                !same_identity(&old_destination, &final_destination)) {
            delete_identity(backup, &marker);
            free(backup);
            continue;
        }

        HANDLE old_handle = CreateFileW(destination.name,
            FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | DELETE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            NULL, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
        if (old_handle == INVALID_HANDLE_VALUE) {
            DWORD error = GetLastError();
            delete_identity(backup, &marker);
            free(backup);
            if (missing_error(error)) {
                continue;
            }
            publish_win_error(interp,
                "cannot retain the publication destination during replacement",
                error, NULL);
            goto done;
        }
        PublishFileInfo held_destination;
        DWORD held_error;
        if (!query_handle(old_handle, &held_destination, &held_error)) {
            CloseHandle(old_handle);
            delete_identity(backup, &marker);
            free(backup);
            publish_win_error(interp,
                "cannot identify the retained publication destination",
                held_error, NULL);
            goto done;
        }
        if (!is_regular(&held_destination) ||
                !same_identity(&held_destination, &final_destination)) {
            CloseHandle(old_handle);
            delete_identity(backup, &marker);
            free(backup);
            continue;
        }

        if (ReplaceFileW(destination.name, candidate.name, backup, 0,
                NULL, NULL)) {
            delete_backup_after_replace(old_handle);
            CloseHandle(old_handle);
            free(backup);
            Tcl_SetObjResult(interp, objv[2]);
            result = TCL_OK;
            goto done;
        }

        DWORD error = GetLastError();
        int retained = recover_replace_failure(old_handle, backup,
            destination.name, &marker);
        CloseHandle(old_handle);
        if (missing_error(error) && !retained) {
            free(backup);
            continue;
        }
        publish_win_error(interp, "cannot atomically replace the destination",
            error, retained ? backup : NULL);
        free(backup);
        goto done;
    }

    publish_error(interp, "oserror",
        "publication destination changed too often to publish safely");

done:
    native_path_release(&destination_parent);
    native_path_release(&candidate_parent);
    native_path_release(&destination);
    native_path_release(&candidate);
    return result;
}

int
Machteldpublish_Init(Tcl_Interp *interp)
{
    if (Tcl_FindNamespace(interp, "::machteld", NULL, TCL_GLOBAL_ONLY) == NULL &&
            Tcl_CreateNamespace(interp, "::machteld", NULL, NULL) == NULL) {
        return publish_error(interp, "oserror",
            "cannot create the machteld command namespace");
    }
    if (Tcl_CreateObjCommand(interp, "::machteld::Publish", PublishCmd,
            NULL, NULL) == NULL) {
        return publish_error(interp, "oserror",
            "cannot register the atomic publication primitive");
    }
    return TCL_OK;
}
