/* Atomic publication of a completed file into a Windows namespace. */
#undef USE_TCL_STUBS
#include "machteld.h"

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
    ULONGLONG size;
    FILETIME written;
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
    Tcl_SetErrorCode(interp, "MACHTELD", "PUBLISH", code, NULL);
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
    Tcl_SetErrorCode(interp, "MACHTELD", "PUBLISH", "oserror", NULL);
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
        Tcl_SetErrorCode(interp, "MACHTELD", "PUBLISH", "badvalue", NULL);
        return TCL_ERROR;
    }
    /* Tcl's string representation encodes NUL as C0 80. Checking the C
     * string for zero bytes misses it; Windows would silently use the prefix
     * of the converted native path and could replace a different file. */
    Tcl_Size count;
    const Tcl_UniChar *characters = Tcl_GetUnicodeFromObj(value, &count);
    for (Tcl_Size i = 0; i < count; ++i) {
        if (characters[i] == 0 ||
                (characters[i] >= 0xd800 && characters[i] <= 0xdfff)) {
            return publish_error(interp, "badvalue",
                "publication paths must contain valid Unicode without NUL");
        }
    }

    Tcl_Obj *normalized = Tcl_FSGetNormalizedPath(interp, value);
    if (normalized == NULL) {
        Tcl_ResetResult(interp);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s is not a usable path", label));
        Tcl_SetErrorCode(interp, "MACHTELD", "PUBLISH", "badvalue", NULL);
        return TCL_ERROR;
    }
    Tcl_IncrRefCount(normalized);
    const void *native = Tcl_FSGetNativePath(normalized);
    if (native == NULL) {
        Tcl_DecrRefCount(normalized);
        Tcl_ResetResult(interp);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(
            "%s must be on the native Windows filesystem", label));
        Tcl_SetErrorCode(interp, "MACHTELD", "PUBLISH", "badvalue", NULL);
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
        Tcl_SetErrorCode(interp, "MACHTELD", "PUBLISH", "badvalue", NULL);
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
        info->size = ((ULONGLONG)legacy.nFileSizeHigh << 32) | legacy.nFileSizeLow;
        info->written = legacy.ftLastWriteTime;
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
        Tcl_SetErrorCode(interp, "MACHTELD", "PUBLISH", "badvalue", NULL);
        return TCL_ERROR;
    }
    if (state == PUBLISH_PROBE_ERROR) {
        return publish_win_error(interp,
            "cannot inspect the publication parent directory", error, NULL);
    }
    if (!is_plain_directory(info)) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(
            "%s must be a directory and not a reparse point", label));
        Tcl_SetErrorCode(interp, "MACHTELD", "PUBLISH", "badvalue", NULL);
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

typedef enum {
    PRIOR_UNVERIFIED,
    PRIOR_AT_DESTINATION,
    PRIOR_AT_BACKUP
} PriorLocation;

typedef struct {
    PriorLocation prior;
    int backup_absent;
} ReplaceRecovery;

static int
probe_recovery_path(const wchar_t *path, PublishFileInfo *info)
{
    DWORD ignored;
    return probe_path(path, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, info, &ignored);
}

/* The held handle keeps the original file ID live. An inaccessible path or
 * an unremoved reservation cannot establish the location of the old file. */
static ReplaceRecovery
recover_replace_failure(const PublishFileInfo *held, const wchar_t *backup,
                        const wchar_t *destination, const PublishFileInfo *marker)
{
    PublishFileInfo at_backup, at_destination;
    int backup_state = probe_recovery_path(backup, &at_backup);
    if (backup_state == PUBLISH_PROBE_PRESENT && is_regular(&at_backup)) {
        if (same_identity(&at_backup, marker)) {
            delete_identity(backup, marker);
        } else if (same_identity(&at_backup, held) &&
                probe_recovery_path(destination, &at_destination) == PUBLISH_PROBE_ABSENT) {
            /* No replacement flag: a new occupant of the name wins. */
            MoveFileExW(backup, destination, 0);
        }
    }

    /* Recheck both names after any restoration or cleanup attempt. */
    backup_state = probe_recovery_path(backup, &at_backup);
    int destination_state = probe_recovery_path(destination, &at_destination);
    ReplaceRecovery recovery = {PRIOR_UNVERIFIED, backup_state == PUBLISH_PROBE_ABSENT};
    if (destination_state == PUBLISH_PROBE_PRESENT && is_regular(&at_destination) &&
            same_identity(&at_destination, held)) {
        recovery.prior = PRIOR_AT_DESTINATION;
    } else if (backup_state == PUBLISH_PROBE_PRESENT && is_regular(&at_backup) &&
            same_identity(&at_backup, held)) {
        recovery.prior = PRIOR_AT_BACKUP;
    }
    return recovery;
}

/* Retry only when the names still refer to the same completed file versions.
 * A filesystem that cannot provide size and write time gets one attempt. */
static int
same_file_version(const PublishFileInfo *left, const PublishFileInfo *right)
{
    return left->identity.has_legacy && right->identity.has_legacy &&
           is_regular(left) && is_regular(right) && same_identity(left, right) &&
           left->size == right->size &&
           CompareFileTime(&left->written, &right->written) == 0;
}

static int
same_parent_at_path(const NativePath *path, const PublishFileInfo *expected)
{
    PublishFileInfo current;
    return probe_recovery_path(path->name, &current) == PUBLISH_PROBE_PRESENT &&
           is_plain_directory(&current) && same_identity(&current, expected);
}


/* Reopen the published name and hold it stable through the flush. If another
 * writer won the name between replacement and open, its flush cannot confirm
 * our bytes. The original publication has already succeeded in either case. */
static int
confirm_published(Tcl_Interp *interp, const NativePath *destination,
                  const PublishFileInfo *candidate)
{
    DWORD error = ERROR_SUCCESS;
    HANDLE file = CreateFileW(destination->name, GENERIC_WRITE, FILE_SHARE_READ,
        NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        error = GetLastError();
    } else {
        PublishFileInfo found;
        if (query_handle(file, &found, &error)) {
            if (!is_regular(&found) || !same_identity(candidate, &found)) {
                error = ERROR_FILE_INVALID;
            } else if (!FlushFileBuffers(file)) {
                error = GetLastError();
            }
        }
        CloseHandle(file);
    }
    if (error != ERROR_SUCCESS) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(
            "published the file, but could not confirm its flush (Windows error %lu)",
            (unsigned long)error));
        Tcl_SetErrorCode(interp, "MACHTELD", "PUBLISH", "unconfirmed", NULL);
        return TCL_ERROR;
    }
    return TCL_OK;
}

static int
PublishCmd(void *client_data, Tcl_Interp *interp, int objc,
           Tcl_Obj *const objv[])
{
    (void)client_data;
    int create_only = objc == 4 && strcmp(Tcl_GetString(objv[3]), "-createonly") == 0;
    int flush = objc == 4 && strcmp(Tcl_GetString(objv[3]), "-flush") == 0;
    if (objc != 3 && !create_only && !flush) {
        return publish_error(interp, "badvalue",
            "usage: ::machteld::Publish candidate destination ?-createonly|-flush?");
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

    if (create_only) {
        /* No preflight existence test or replacement fallback. The filesystem
         * selects the winner atomically even if another process just created
         * the name after the database integrity check. */
        if (MoveFileExW(candidate.name, destination.name, 0)) {
            Tcl_SetObjResult(interp, objv[2]);
            result = TCL_OK;
        } else {
            DWORD error = GetLastError();
            if (exists_error(error)) {
                publish_error(interp, "exists", "publication destination already exists");
            } else {
                publish_win_error(interp, "cannot create publication destination", error, NULL);
            }
        }
        goto done;
    }

    unsigned int replace_retries = 0;
    PublishFileInfo retry_destination = {0};
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
        if (replace_retries != 0 &&
                (state != PUBLISH_PROBE_PRESENT ||
                 !same_file_version(&original_candidate, &current_candidate) ||
                 !same_file_version(&retry_destination, &old_destination) ||
                 !same_parent_at_path(&candidate_parent, &candidate_parent_info) ||
                 !same_parent_at_path(&destination_parent, &destination_parent_info))) {
            publish_win_error(interp, "cannot retry replacement after an input changed",
                ERROR_UNABLE_TO_REMOVE_REPLACED, NULL);
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

        if (replace_retries != 0 &&
                (!same_file_version(&original_candidate, &final_candidate) ||
                 !same_file_version(&retry_destination, &held_destination))) {
            CloseHandle(old_handle);
            delete_identity(backup, &marker);
            free(backup);
            publish_win_error(interp, "cannot retry replacement after an input changed",
                ERROR_UNABLE_TO_REMOVE_REPLACED, NULL);
            goto done;
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
        ReplaceRecovery recovery = recover_replace_failure(&held_destination, backup,
            destination.name, &marker);
        CloseHandle(old_handle);
        if (recovery.prior == PRIOR_AT_DESTINATION && recovery.backup_absent) {
            if (missing_error(error)) {
                free(backup);
                continue;
            }
            if (error == ERROR_UNABLE_TO_REMOVE_REPLACED && replace_retries < 3 && attempt < 7 &&
                    original_candidate.identity.has_legacy && held_destination.identity.has_legacy) {
                if (replace_retries == 0) retry_destination = held_destination;
                free(backup);
                Sleep(10U << replace_retries);
                ++replace_retries;
                continue;
            }
        }
        publish_win_error(interp, recovery.prior == PRIOR_UNVERIFIED
            ? "cannot atomically replace the destination or verify the prior file's location"
            : "cannot atomically replace the destination",
            error, recovery.prior == PRIOR_AT_BACKUP ? backup : NULL);
        free(backup);
        goto done;
    }

    publish_error(interp, "oserror",
        "publication destination changed too often to publish safely");

done:
    if (result == TCL_OK && flush) {
        result = confirm_published(interp, &destination, &original_candidate);
    }
    native_path_release(&destination_parent);
    native_path_release(&candidate_parent);
    native_path_release(&destination);
    native_path_release(&candidate);
    return result;
}

/* Write to the public command's private, blocking binary staging channel.
 * Use the same byte/text distinction as hash, the store and child stdin. */
/* Capture the new stage's ID from the writable channel itself. The private
 * binary token contains no pointers and is only used during this call to
 * publish bytes. Removing by an identity-checked handle keeps a new occupant
 * of the temporary pathname untouched. */
static int
PublishCleanupCmd(void *unused, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    (void)unused;
    PublishFileInfo owned = {0};
    if (objc == 2) {
        int mode;
        void *handle;
        DWORD error = ERROR_INVALID_HANDLE;
        Tcl_Channel channel = Tcl_GetChannel(interp, Tcl_GetString(objv[1]), &mode);
        if (channel == NULL || !(mode & TCL_WRITABLE) ||
                Tcl_GetChannelHandle(channel, TCL_WRITABLE, &handle) != TCL_OK ||
                !query_handle(handle, &owned, &error) || !is_regular(&owned)) {
            return publish_win_error(interp, "cannot identify the new publication stage", error, NULL);
        }
        Tcl_SetObjResult(interp, Tcl_NewByteArrayObj((const unsigned char *)&owned.identity,
            sizeof owned.identity));
        return TCL_OK;
    }
    if (objc == 3) {
        Tcl_Size size;
        const unsigned char *token = Tcl_GetBytesFromObj(interp, objv[2], &size);
        if (token == NULL || size != sizeof owned.identity) {
            return publish_error(interp, "badvalue", "invalid publication stage identity");
        }
        memcpy(&owned.identity, token, sizeof owned.identity);
        NativePath stage = {0};
        if (native_path_from_obj(interp, objv[1], "publication stage", &stage) != TCL_OK) {
            return TCL_ERROR;
        }
        int removed = delete_identity(stage.name, &owned);
        native_path_release(&stage);
        Tcl_SetObjResult(interp, Tcl_NewBooleanObj(removed));
        return TCL_OK;
    }
    Tcl_WrongNumArgs(interp, 1, objv, "channel | path identity");
    return TCL_ERROR;
}

static int
PublishWriteCmd(void *client_data, Tcl_Interp *interp, int objc,
                Tcl_Obj *const objv[])
{
    (void)client_data;
    if (objc != 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "channel value");
        return TCL_ERROR;
    }
    int mode;
    Tcl_Channel channel = Tcl_GetChannel(interp, Tcl_GetString(objv[1]), &mode);
    if (channel == NULL || !(mode & TCL_WRITABLE)) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("cannot write to the publication channel", -1));
        return TCL_ERROR;
    }
    Tcl_Size size;
    Tcl_DString converted;
    const unsigned char *data = Machteld_ValueBytes(objv[2], &size, &converted);
    Tcl_Size written = Tcl_Write(channel, (const char *)data, size);
    Tcl_DStringFree(&converted);
    if (written != size) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("cannot write the publication candidate: %s",
                                              Tcl_PosixError(interp)));
        return TCL_ERROR;
    }
    return TCL_OK;
}

/* The verified reference tree is authored in one exclusively created sibling
 * directory. Unlike Tcl's "file rename a b", publication must fail when b
 * is an existing directory, without moving a beneath it. */
static int
DirectoryStageCmd(void *client_data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    (void)client_data;
    int create = objc == 3 && strcmp(Tcl_GetString(objv[1]), "create") == 0;
    if (!create && !(objc == 4 && strcmp(Tcl_GetString(objv[1]), "publish") == 0)) {
        return publish_error(interp, "badvalue", "expected create path or publish staged destination");
    }
    NativePath stage = {0}, target = {0}, stage_parent = {0}, target_parent = {0};
    PublishFileInfo src_parent, dst_parent, staged;
    int result = TCL_ERROR;
    if (native_path_from_obj(interp, objv[2], "staging directory", &stage) != TCL_OK ||
            native_parent(interp, &stage, "staging directory", &stage_parent) != TCL_OK ||
            check_parent(interp, &stage_parent, "staging parent", &src_parent) != TCL_OK) {
        goto done;
    }
    if (create) {
        if (CreateDirectoryW(stage.name, NULL)) {
            result = TCL_OK;
        } else {
            DWORD e = GetLastError();
            if (exists_error(e)) publish_error(interp, "exists", "staging directory already exists");
            else publish_win_error(interp, "cannot create staging directory", e, NULL);
        }
        goto done;
    }
    if (native_path_from_obj(interp, objv[3], "directory destination", &target) != TCL_OK ||
            native_parent(interp, &target, "directory destination", &target_parent) != TCL_OK ||
            check_parent(interp, &target_parent, "destination parent", &dst_parent) != TCL_OK ||
            check_parent(interp, &stage, "staging directory", &staged) != TCL_OK) {
        goto done;
    }
    if (!same_identity(&src_parent, &dst_parent)) {
        publish_error(interp, "badvalue", "staging and destination directories must be siblings");
        goto done;
    }
    /* A transient file-scanner handle can briefly deny a directory rename.
     * Recheck the source identity before each retry and never replace a name. */
    for (int attempt = 0; ; attempt++) {
        if (MoveFileExW(stage.name, target.name, 0)) {
            result = TCL_OK;
            break;
        }
        DWORD e = GetLastError();
        if (exists_error(e) || GetFileAttributesW(target.name) != INVALID_FILE_ATTRIBUTES) {
            publish_error(interp, "exists", "directory destination already exists");
            break;
        }
        if (attempt == 4 || (e != ERROR_SHARING_VIOLATION && e != ERROR_ACCESS_DENIED)) {
            publish_win_error(interp, "cannot publish staged directory", e, NULL);
            break;
        }
        Sleep(20U << attempt);
        PublishFileInfo current;
        if (check_parent(interp, &stage, "staging directory", &current) != TCL_OK) break;
        if (!same_identity(&staged, &current)) {
            publish_error(interp, "badvalue", "staging directory changed during publication");
            break;
        }
    }
done:
    native_path_release(&target_parent);
    native_path_release(&stage_parent);
    native_path_release(&target);
    native_path_release(&stage);
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
    if (Tcl_CreateObjCommand(interp, "::machteld::DirectoryStage", DirectoryStageCmd,
            NULL, NULL) == NULL ||
        Tcl_CreateObjCommand(interp, "::machteld::PublishCleanup", PublishCleanupCmd,
            NULL, NULL) == NULL ||
        Tcl_CreateObjCommand(interp, "::machteld::Publish", PublishCmd,
            NULL, NULL) == NULL ||
            Tcl_CreateObjCommand(interp, "::machteld::PublishWrite", PublishWriteCmd,
            NULL, NULL) == NULL) {
        return publish_error(interp, "oserror",
            "cannot register the atomic publication primitive");
    }
    return TCL_OK;
}
