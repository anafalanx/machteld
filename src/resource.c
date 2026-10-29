/* Private, compiler-free identity stamping for disposable wrapper basekits.
 * All inputs are validated before BeginUpdateResource; the ZIP payload is
 * attached by the Tcl wrapper only after this operation has completed. */
#undef USE_TCL_STUBS
#include "machteld.h"
#include "wintext.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define ID_TEXT_MAX 1024
#define ID_ICON_MAX (16u * 1024u * 1024u)
#define ID_ICON_COUNT_MAX 256
#define ID_RESOURCE_MAX 65535
#define ID_LANGUAGE 0x0409

enum { ID_NAME, ID_DESCRIPTION, ID_VERSION, ID_AUTHOR, ID_PUBLISHER,
       ID_COPYRIGHT, ID_INTERNAL, ID_ORIGINAL, ID_ICON, ID_FIELD_COUNT };
static const char *const identity_keys[] = {
    "name", "description", "version", "author", "publisher", "copyright",
    "internal_name", "original_filename", "icon", NULL
};

typedef struct {
    Tcl_Obj *normalized;
    wchar_t *text[ID_FIELD_COUNT];
    WORD version[4];
    unsigned char *icon;
    DWORD icon_size;
    WORD icon_count;
} Identity;

typedef struct {
    unsigned char bytes[ID_RESOURCE_MAX];
    size_t length;
    int failed;
} VersionBuffer;

static WORD read16(const unsigned char *p) {
    return (WORD)((unsigned)p[0] | ((unsigned)p[1] << 8));
}
static DWORD read32(const unsigned char *p) {
    return (DWORD)p[0] | ((DWORD)p[1] << 8) |
        ((DWORD)p[2] << 16) | ((DWORD)p[3] << 24);
}
static DWORD read32be(const unsigned char *p) {
    return ((DWORD)p[0] << 24) | ((DWORD)p[1] << 16) |
        ((DWORD)p[2] << 8) | (DWORD)p[3];
}
static void put16(unsigned char *p, WORD value) {
    p[0] = (unsigned char)value; p[1] = (unsigned char)(value >> 8);
}
static void put32(unsigned char *p, DWORD value) {
    for (unsigned i = 0; i < 4; i++) p[i] = (unsigned char)(value >> (8 * i));
}
static int identity_error(Tcl_Interp *interp, const char *code, const char *message) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(message, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", code, NULL);
    return TCL_ERROR;
}
static int identity_win_error(Tcl_Interp *interp, const char *message, DWORD error) {
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s (Windows error %lu)",
        message, (unsigned long)error));
    Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "oserror", NULL);
    return TCL_ERROR;
}
static void identity_free(Identity *identity) {
    for (int i = 0; i < ID_FIELD_COUNT; i++) free(identity->text[i]);
    free(identity->icon);
    if (identity->normalized != NULL) Tcl_DecrRefCount(identity->normalized);
    memset(identity, 0, sizeof *identity);
}

/* Tcl 9 characters are Unicode scalar-sized, not Windows wchar_t units. Count
 * the actual UTF-16 units and reject malformed scalars before strict encoding. */
static int identity_text(Tcl_Interp *interp, Tcl_Obj *value, int field,
                         wchar_t **result) {
    Tcl_Size count = Tcl_GetCharLength(value);
    Tcl_Size limit = field == ID_ICON ? 32767 :
        (field == ID_VERSION ? 23 : ID_TEXT_MAX);
    if (count > limit) goto invalid;
    Tcl_UniChar *characters = Tcl_GetUnicodeFromObj(value, &count);
    Tcl_Size units = 0;
    for (Tcl_Size i = 0; i < count; i++) {
        uint32_t cp = (uint32_t)characters[i];
        if (cp < 0x20 || (cp >= 0x7f && cp <= 0x9f) ||
                (cp >= 0xd800 && cp <= 0xdfff) || cp > 0x10ffff) goto invalid;
        units += cp > 0xffff ? 2 : 1;
        if (units > limit) goto invalid;
        if ((field == ID_INTERNAL || field == ID_ORIGINAL) &&
                (cp == '/' || cp == '\\' || cp == ':')) goto invalid;
    }
    *result = mt_utf8_to_wide(Tcl_GetString(value));
    if (*result == NULL) return identity_error(interp, "oserror",
        "cannot encode application identity as UTF-16");
    return TCL_OK;
invalid:
    Tcl_SetObjResult(interp, Tcl_ObjPrintf(
        "invalid application identity %s: use bounded Unicode text without control characters or unpaired surrogates",
        identity_keys[field]));
    Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "badvalue", NULL);
    return TCL_ERROR;
}

static int identity_version(Tcl_Interp *interp, Identity *identity) {
    const wchar_t *p = identity->text[ID_VERSION];
    for (int component = 0; component < 4; component++) {
        if (*p < L'0' || *p > L'9') break;
        unsigned number = 0;
        do {
            number = number * 10 + (unsigned)(*p++ - L'0');
            if (number > 65535) goto invalid;
        } while (*p >= L'0' && *p <= L'9');
        identity->version[component] = (WORD)number;
        if (*p == L'\0') return TCL_OK;
        if (*p++ != L'.') break;
    }
invalid:
    return identity_error(interp, "badvalue",
        "application version must have one to four decimal components in 0..65535");
}

static int native_file(Tcl_Interp *interp, Tcl_Obj *value, Tcl_Obj **normalized,
                        const wchar_t **path) {
    wchar_t *checked = NULL;
    if (Tcl_GetCharLength(value) == 0)
        return identity_error(interp, "badvalue", "identity resource path must not be empty");
    if (identity_text(interp, value, ID_ICON, &checked) != TCL_OK) return TCL_ERROR;
    free(checked);
    *normalized = Tcl_FSGetNormalizedPath(interp, value);
    if (*normalized == NULL) return identity_error(interp, "badvalue",
        "identity resource path cannot be normalized");
    Tcl_IncrRefCount(*normalized);
    *path = Tcl_FSGetNativePath(*normalized);
    if (*path == NULL) return identity_error(interp, "badvalue",
        "identity resources require the native Windows filesystem");
    return TCL_OK;
}

static int icon_validate(Tcl_Interp *interp, Identity *identity, Tcl_Obj *value) {
    if (identity->text[ID_ICON][0] == L'\0') return TCL_OK;
    Tcl_Obj *normalized = NULL;
    const wchar_t *path = NULL;
    HANDLE file = INVALID_HANDLE_VALUE;
    int result = TCL_ERROR;
    if (native_file(interp, value, &normalized, &path) != TCL_OK) goto done;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        identity_win_error(interp, "cannot open application icon", GetLastError());
        goto done;
    }
    BY_HANDLE_FILE_INFORMATION info;
    LARGE_INTEGER size;
    if (!GetFileInformationByHandle(file, &info) || !GetFileSizeEx(file, &size)) {
        identity_win_error(interp, "cannot inspect application icon", GetLastError());
        goto done;
    }
    if (GetFileType(file) != FILE_TYPE_DISK ||
            (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
            size.QuadPart < 6 || size.QuadPart > ID_ICON_MAX) {
        identity_error(interp, "badvalue", "icon must be a regular .ico file of at most 16 MiB");
        goto done;
    }
    identity->icon_size = (DWORD)size.QuadPart;
    identity->icon = malloc(identity->icon_size);
    if (identity->icon == NULL) {
        identity_error(interp, "oserror", "out of memory reading application icon");
        goto done;
    }
    DWORD count;
    if (!ReadFile(file, identity->icon, identity->icon_size, &count, NULL) ||
            count != identity->icon_size) {
        identity_win_error(interp, "cannot read application icon", GetLastError());
        goto done;
    }
    const unsigned char *data = identity->icon;
    identity->icon_count = read16(data + 4);
    if (read16(data) != 0 || read16(data + 2) != 1 ||
            identity->icon_count == 0 || identity->icon_count > ID_ICON_COUNT_MAX ||
            6u + 16u * identity->icon_count > identity->icon_size) goto malformed;
    DWORD directory_end = 6u + 16u * identity->icon_count;
    for (WORD i = 0; i < identity->icon_count; i++) {
        const unsigned char *entry = data + 6 + 16u * i;
        DWORD bytes = read32(entry + 8), offset = read32(entry + 12);
        unsigned width = entry[0] ? entry[0] : 256;
        unsigned height = entry[1] ? entry[1] : 256;
        WORD directory_depth = read16(entry + 6);
        if (entry[3] != 0 || bytes < 12 || offset < directory_end ||
                offset > identity->icon_size || bytes > identity->icon_size - offset ||
                read16(entry + 4) > 1 || (directory_depth != 0 && directory_depth != 1 &&
                directory_depth != 4 && directory_depth != 8 && directory_depth != 16 &&
                directory_depth != 24 && directory_depth != 32)) goto malformed;
        for (WORD j = 0; j < i; j++) {
            const unsigned char *prior = data + 6 + 16u * j;
            DWORD prior_size = read32(prior + 8), prior_offset = read32(prior + 12);
            if (offset < prior_offset + prior_size && prior_offset < offset + bytes) goto malformed;
        }
        const unsigned char *image = data + offset;
        static const unsigned char png[] = {137, 80, 78, 71, 13, 10, 26, 10};
        if (bytes >= 8 && memcmp(image, png, sizeof png) == 0) {
            if (bytes < 33 || read32be(image + 8) != 13 ||
                    memcmp(image + 12, "IHDR", 4) != 0 ||
                    read32be(image + 16) != width || read32be(image + 20) != height) goto malformed;
        } else {
            DWORD header = read32(image);
            if ((header != 40 && header != 108 && header != 124) || bytes < header ||
                    read32(image + 4) != width || read32(image + 8) != height * 2 ||
                    read16(image + 12) != 1) goto malformed;
            unsigned depth = read16(image + 14);
            DWORD compression = read32(image + 16);
            if ((depth != 1 && depth != 4 && depth != 8 && depth != 16 && depth != 24 && depth != 32) ||
                    (compression != BI_RGB && compression != BI_BITFIELDS) ||
                    (compression == BI_BITFIELDS && depth != 16 && depth != 32) ||
                    (directory_depth != 0 && directory_depth != depth)) goto malformed;
            /* Check uncompressed row/mask storage before the OS decoder sees
             * any DIB. Windows may omit an AND mask for 32-bit alpha icons. */
            uint64_t colors = read32(image + 32);
            if (colors == 0 && depth <= 8) colors = (uint64_t)1 << depth;
            if (colors > 256 || (depth > 8 && colors != 0)) goto malformed;
            uint64_t masks = header == 40 && compression == BI_BITFIELDS ? 12 : 0;
            uint64_t xor_bytes = (((uint64_t)width * depth + 31) / 32) * 4 * height;
            uint64_t and_bytes = ((width + 31u) / 32u) * 4u * height;
            uint64_t required = header + masks + colors * 4 + xor_bytes;
            if (required > bytes || (depth != 32 && required + and_bytes > bytes)) goto malformed;
        }
        HICON icon = CreateIconFromResourceEx((PBYTE)image, bytes, TRUE,
            0x00030000, (int)width, (int)height, LR_DEFAULTCOLOR);
        if (icon == NULL) goto malformed;
        DestroyIcon(icon);
    }
    result = TCL_OK;
    goto done;
malformed:
    identity_error(interp, "badvalue", "invalid .ico: require 1..256 nonoverlapping, valid PNG or DIB images of 1..256 pixels");
done:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (normalized != NULL) Tcl_DecrRefCount(normalized);
    return result;
}

static int identity_validate(Tcl_Interp *interp, Tcl_Obj *metadata, Identity *identity) {
    memset(identity, 0, sizeof *identity);
    Tcl_Size size;
    if (Tcl_DictObjSize(interp, metadata, &size) != TCL_OK || size > ID_FIELD_COUNT)
        return identity_error(interp, "badvalue", "application identity must be a dictionary with known metadata keys");
    Tcl_Obj *values[ID_FIELD_COUNT] = {0};
    Tcl_DictSearch search;
    Tcl_Obj *key, *value;
    int done;
    if (Tcl_DictObjFirst(interp, metadata, &search, &key, &value, &done) != TCL_OK)
        return identity_error(interp, "badvalue", "invalid application identity dictionary");
    while (!done) {
        int index;
        if (Tcl_GetIndexFromObj(interp, key, identity_keys, "identity key", TCL_EXACT, &index) != TCL_OK) {
            Tcl_DictObjDone(&search);
            return identity_error(interp, "badvalue", "unknown application identity key");
        }
        values[index] = value;
        Tcl_DictObjNext(&search, &key, &value, &done);
    }
    Tcl_DictObjDone(&search);
    static const int required[] = {ID_NAME, ID_VERSION, ID_INTERNAL, ID_ORIGINAL};
    for (size_t i = 0; i < sizeof required / sizeof required[0]; i++) {
        int field = required[i];
        if (values[field] == NULL || Tcl_GetCharLength(values[field]) == 0) {
            Tcl_SetObjResult(interp, Tcl_ObjPrintf("application identity requires nonempty %s", identity_keys[field]));
            Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "badvalue", NULL);
            return TCL_ERROR;
        }
    }
    if (values[ID_DESCRIPTION] == NULL) values[ID_DESCRIPTION] = values[ID_NAME];
    identity->normalized = Tcl_NewDictObj();
    Tcl_IncrRefCount(identity->normalized);
    for (int i = 0; i < ID_FIELD_COUNT; i++) {
        Tcl_Obj *item = values[i] == NULL ? Tcl_NewStringObj("", 0) : values[i];
        values[i] = item;
        Tcl_DictObjPut(interp, identity->normalized, Tcl_NewStringObj(identity_keys[i], -1), item);
        if (identity_text(interp, item, i, &identity->text[i]) != TCL_OK) return TCL_ERROR;
    }
    if (identity_version(interp, identity) != TCL_OK) return TCL_ERROR;
    return icon_validate(interp, identity, values[ID_ICON]);
}

static void buffer_bytes(VersionBuffer *buffer, const void *data, size_t count) {
    if (count > sizeof buffer->bytes - buffer->length) { buffer->failed = 1; return; }
    memcpy(buffer->bytes + buffer->length, data, count);
    buffer->length += count;
}
static void buffer_word(VersionBuffer *buffer, WORD value) {
    unsigned char bytes[2]; put16(bytes, value); buffer_bytes(buffer, bytes, 2);
}
static void buffer_dword(VersionBuffer *buffer, DWORD value) {
    unsigned char bytes[4]; put32(bytes, value); buffer_bytes(buffer, bytes, 4);
}
static void buffer_align(VersionBuffer *buffer) {
    while (buffer->length % 4 != 0 && !buffer->failed) buffer_word(buffer, 0);
}
static void buffer_text(VersionBuffer *buffer, const wchar_t *text) {
    do { buffer_word(buffer, (WORD)*text); } while (*text++ != L'\0' && !buffer->failed);
}
static size_t buffer_begin(VersionBuffer *buffer, const wchar_t *key, WORD length, WORD type) {
    buffer_align(buffer);
    size_t start = buffer->length;
    buffer_word(buffer, 0); buffer_word(buffer, length); buffer_word(buffer, type);
    buffer_text(buffer, key); buffer_align(buffer);
    return start;
}
static void buffer_end(VersionBuffer *buffer, size_t start) {
    if (!buffer->failed && start + 2 <= buffer->length)
        put16(buffer->bytes + start, (WORD)(buffer->length - start));
}
static void buffer_string(VersionBuffer *buffer, const wchar_t *key, const wchar_t *value) {
    size_t start = buffer_begin(buffer, key, (WORD)(wcslen(value) + 1), 1);
    buffer_text(buffer, value); buffer_end(buffer, start);
}
static int version_build(Tcl_Interp *interp, const Identity *identity, VersionBuffer *buffer) {
    memset(buffer, 0, sizeof *buffer);
    size_t root = buffer_begin(buffer, L"VS_VERSION_INFO", 52, 0);
    buffer_dword(buffer, 0xfeef04bd); buffer_dword(buffer, 0x00010000);
    DWORD major = ((DWORD)identity->version[0] << 16) | identity->version[1];
    DWORD minor = ((DWORD)identity->version[2] << 16) | identity->version[3];
    buffer_dword(buffer, major); buffer_dword(buffer, minor);
    buffer_dword(buffer, major); buffer_dword(buffer, minor);
    buffer_dword(buffer, VS_FFI_FILEFLAGSMASK); buffer_dword(buffer, 0);
    buffer_dword(buffer, VOS_NT_WINDOWS32); buffer_dword(buffer, VFT_APP);
    buffer_dword(buffer, 0); buffer_dword(buffer, 0); buffer_dword(buffer, 0);
    size_t strings = buffer_begin(buffer, L"StringFileInfo", 0, 1);
    size_t table = buffer_begin(buffer, L"040904B0", 0, 1);
    buffer_string(buffer, L"Author", identity->text[ID_AUTHOR]);
    buffer_string(buffer, L"CompanyName", identity->text[ID_PUBLISHER]);
    buffer_string(buffer, L"FileDescription", identity->text[ID_DESCRIPTION]);
    buffer_string(buffer, L"FileVersion", identity->text[ID_VERSION]);
    buffer_string(buffer, L"InternalName", identity->text[ID_INTERNAL]);
    buffer_string(buffer, L"LegalCopyright", identity->text[ID_COPYRIGHT]);
    buffer_string(buffer, L"OriginalFilename", identity->text[ID_ORIGINAL]);
    buffer_string(buffer, L"ProductName", identity->text[ID_NAME]);
    buffer_string(buffer, L"ProductVersion", identity->text[ID_VERSION]);
    wchar_t *runtime_version = mt_utf8_to_wide(MACHTELD_VERSION);
    if (runtime_version == NULL) return identity_error(interp, "oserror", "cannot encode runtime identity");
    buffer_string(buffer, L"MachteldRuntimeVersion", runtime_version);
    free(runtime_version);
    buffer_string(buffer, L"MachteldRuntimeAuthor", L"Vincent Vercauteren");
    buffer_end(buffer, table); buffer_end(buffer, strings);
    size_t vars = buffer_begin(buffer, L"VarFileInfo", 0, 1);
    size_t translation = buffer_begin(buffer, L"Translation", 4, 0);
    buffer_word(buffer, ID_LANGUAGE); buffer_word(buffer, 1200);
    buffer_end(buffer, translation); buffer_end(buffer, vars); buffer_end(buffer, root);
    if (buffer->failed) return identity_error(interp, "badvalue", "application version resource exceeds 65535 bytes");
    return TCL_OK;
}

static int read_at(HANDLE file, LONGLONG offset, void *bytes, DWORD count) {
    LARGE_INTEGER position; position.QuadPart = offset;
    DWORD received;
    return SetFilePointerEx(file, position, NULL, FILE_BEGIN) &&
        ReadFile(file, bytes, count, &received, NULL) && received == count;
}

/* Resource rewriting is deliberately limited to bare, unsigned PE images.
 * In particular, Windows' resource API must never rewrite a zipfs overlay. */
static int bare_validate(Tcl_Interp *interp, const wchar_t *path) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
        OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE)
        return identity_win_error(interp, "cannot open wrapper basekit", GetLastError());
    int result = TCL_ERROR;
    BY_HANDLE_FILE_INFORMATION info;
    LARGE_INTEGER size;
    unsigned char dos[64], nt[24], optional[512], section[40];
    if (!GetFileInformationByHandle(file, &info) || !GetFileSizeEx(file, &size)) {
        identity_win_error(interp, "cannot inspect wrapper basekit", GetLastError());
        goto done;
    }
    if (GetFileType(file) != FILE_TYPE_DISK || info.nNumberOfLinks != 1 ||
            (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) goto invalid;
    if (size.QuadPart < 64 || !read_at(file, 0, dos, sizeof dos) || read16(dos) != 0x5a4d) goto invalid;
    DWORD pe = read32(dos + 60);
    if (pe < 64 || pe > 1048576 || !read_at(file, pe, nt, sizeof nt) || read32(nt) != 0x00004550) goto invalid;
    WORD sections = read16(nt + 6), optional_size = read16(nt + 20);
    if (sections == 0 || sections > 96 || optional_size > sizeof optional || optional_size < 128 ||
            !read_at(file, (LONGLONG)pe + 24, optional, optional_size)) goto invalid;
    WORD magic = read16(optional);
    unsigned directory = magic == 0x20b ? 112 : (magic == 0x10b ? 96 : 0);
    if (directory == 0 || directory + 8 * 5 > optional_size ||
            read32(optional + directory - 4) < 5 ||
            read32(optional + directory + 8 * 4) != 0 ||
            read32(optional + directory + 8 * 4 + 4) != 0) goto invalid;
    DWORD headers = read32(optional + 60);
    uint64_t table = (uint64_t)pe + 24 + optional_size;
    uint64_t end = headers;
    if (table + (uint64_t)sections * 40 > headers || headers > (uint64_t)size.QuadPart) goto invalid;
    for (WORD i = 0; i < sections; i++) {
        if (!read_at(file, (LONGLONG)(table + 40u * i), section, sizeof section)) goto invalid;
        DWORD bytes = read32(section + 16), offset = read32(section + 20);
        if (bytes == 0) continue;
        uint64_t finish = (uint64_t)offset + bytes;
        if (offset < headers || finish > (uint64_t)size.QuadPart) goto invalid;
        if (finish > end) end = finish;
    }
    if (end != (uint64_t)size.QuadPart) goto invalid;
    result = TCL_OK;
    goto done;
invalid:
    identity_error(interp, "badvalue", "identity stamping requires an unsigned, single-link bare PE without an appended payload");
done:
    CloseHandle(file);
    return result;
}

typedef struct { WORD type, language; wchar_t *name; } ExistingResource;
typedef struct {
    ExistingResource items[1024];
    size_t count;
    DWORD error;
} ResourceList;

static BOOL CALLBACK resource_language(HMODULE module, LPCWSTR type, LPCWSTR name,
                                       WORD language, LONG_PTR parameter) {
    (void)module;
    ResourceList *list = (ResourceList *)parameter;
    if (list->count == sizeof list->items / sizeof list->items[0]) {
        list->error = ERROR_RESOURCE_DATA_NOT_FOUND; return FALSE;
    }
    wchar_t *copy;
    if (IS_INTRESOURCE(name)) copy = (wchar_t *)name;
    else {
        size_t length = wcslen(name);
        if (length > 1024 || (copy = malloc((length + 1) * sizeof *copy)) == NULL) {
            list->error = ERROR_NOT_ENOUGH_MEMORY; return FALSE;
        }
        memcpy(copy, name, (length + 1) * sizeof *copy);
    }
    list->items[list->count++] = (ExistingResource){(WORD)(ULONG_PTR)type, language, copy};
    return TRUE;
}
static BOOL CALLBACK resource_name(HMODULE module, LPCWSTR type, LPWSTR name,
                                   LONG_PTR parameter) {
    ResourceList *list = (ResourceList *)parameter;
    if (!EnumResourceLanguagesW(module, type, name, resource_language, parameter)) {
        if (list->error == 0) list->error = GetLastError();
        return FALSE;
    }
    return TRUE;
}
static void resource_list_free(ResourceList *list) {
    for (size_t i = 0; i < list->count; i++)
        if (!IS_INTRESOURCE(list->items[i].name)) free(list->items[i].name);
}
static int resource_list(Tcl_Interp *interp, const wchar_t *path,
                         int icons, ResourceList *list) {
    memset(list, 0, sizeof *list);
    HMODULE module = LoadLibraryExW(path, NULL, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
    if (module == NULL) return identity_win_error(interp, "cannot inspect basekit resources", GetLastError());
    const WORD types[] = {16, 3, 14};
    for (size_t i = 0; i < (icons ? 3u : 1u); i++) {
        if (!EnumResourceNamesW(module, MAKEINTRESOURCEW(types[i]), resource_name, (LONG_PTR)list)) {
            DWORD error = list->error ? list->error : GetLastError();
            if (error != ERROR_RESOURCE_TYPE_NOT_FOUND) { list->error = error; break; }
        }
    }
    FreeLibrary(module);
    if (list->error != 0) return identity_win_error(interp, "cannot enumerate basekit resources", list->error);
    return TCL_OK;
}

static int ValidateIdentityCmd(void *client_data, Tcl_Interp *interp,
                               int objc, Tcl_Obj *const objv[]) {
    (void)client_data;
    if (objc != 2) return identity_error(interp, "usage", "usage: ValidateIdentity metadataDict");
    Identity identity;
    int result = identity_validate(interp, objv[1], &identity);
    if (result == TCL_OK) Tcl_SetObjResult(interp, identity.normalized);
    identity_free(&identity);
    return result;
}

static int StampIdentityCmd(void *client_data, Tcl_Interp *interp,
                            int objc, Tcl_Obj *const objv[]) {
    (void)client_data;
    if (objc != 3) return identity_error(interp, "usage", "usage: StampIdentity barePath metadataDict");
    Identity identity;
    int result = identity_validate(interp, objv[2], &identity);
    Tcl_Obj *normalized = NULL;
    const wchar_t *path = NULL;
    VersionBuffer *buffer = NULL;
    ResourceList *resources = NULL;
    HANDLE update = NULL;
    if (result != TCL_OK) goto done;
    result = TCL_ERROR;
    if (native_file(interp, objv[1], &normalized, &path) != TCL_OK ||
            bare_validate(interp, path) != TCL_OK) goto done;
    buffer = malloc(sizeof *buffer);
    resources = calloc(1, sizeof *resources);
    if (buffer == NULL || resources == NULL) {
        identity_error(interp, "oserror", "out of memory preparing application resources"); goto done;
    }
    if (version_build(interp, &identity, buffer) != TCL_OK ||
            resource_list(interp, path, identity.icon != NULL, resources) != TCL_OK) goto done;
    update = BeginUpdateResourceW(path, FALSE);
    if (update == NULL) {
        identity_win_error(interp, "cannot begin application resource update", GetLastError()); goto done;
    }
    for (size_t i = 0; i < resources->count; i++) {
        const ExistingResource *item = &resources->items[i];
        if (!UpdateResourceW(update, MAKEINTRESOURCEW(item->type), item->name,
                item->language, NULL, 0)) goto update_error;
    }
    if (!UpdateResourceW(update, RT_VERSION, MAKEINTRESOURCEW(1), ID_LANGUAGE,
            buffer->bytes, (DWORD)buffer->length)) goto update_error;
    if (identity.icon != NULL) {
        unsigned char group[6 + 14 * ID_ICON_COUNT_MAX] = {0};
        put16(group + 2, 1); put16(group + 4, identity.icon_count);
        for (WORD i = 0; i < identity.icon_count; i++) {
            const unsigned char *entry = identity.icon + 6 + 16u * i;
            DWORD bytes = read32(entry + 8), offset = read32(entry + 12);
            if (!UpdateResourceW(update, RT_ICON, MAKEINTRESOURCEW(i + 1), ID_LANGUAGE,
                    identity.icon + offset, bytes)) goto update_error;
            memcpy(group + 6 + 14u * i, entry, 12);
            put16(group + 6 + 14u * i + 12, (WORD)(i + 1));
        }
        if (!UpdateResourceW(update, RT_GROUP_ICON, MAKEINTRESOURCEW(1), ID_LANGUAGE,
                group, 6u + 14u * identity.icon_count)) goto update_error;
    }
    if (!EndUpdateResourceW(update, FALSE)) {
        DWORD error = GetLastError(); update = NULL;
        identity_win_error(interp, "cannot finish application resource update", error); goto done;
    }
    update = NULL;
    Tcl_SetObjResult(interp, identity.normalized);
    result = TCL_OK;
    goto done;
update_error:
    identity_win_error(interp, "cannot update application resources", GetLastError());
done:
    if (update != NULL) EndUpdateResourceW(update, TRUE);
    if (resources != NULL) { resource_list_free(resources); free(resources); }
    free(buffer);
    if (normalized != NULL) Tcl_DecrRefCount(normalized);
    identity_free(&identity);
    return result;
}

int Machteldresource_Init(Tcl_Interp *interp) {
    if (Tcl_FindNamespace(interp, "::machteld", NULL, TCL_GLOBAL_ONLY) == NULL &&
            Tcl_CreateNamespace(interp, "::machteld", NULL, NULL) == NULL)
        return identity_error(interp, "oserror", "cannot create identity command namespace");
    if (Tcl_CreateObjCommand(interp, "::machteld::ValidateIdentity", ValidateIdentityCmd, NULL, NULL) == NULL ||
            Tcl_CreateObjCommand(interp, "::machteld::StampIdentity", StampIdentityCmd, NULL, NULL) == NULL)
        return identity_error(interp, "oserror", "cannot register identity primitives");
    return TCL_OK;
}
