/*
 * entry.c -- the narrow boundary between Tcl_Main and a machteld program.
 *
 * Tcl_Main chooses argv0 before it calls AppInit.  Direct native startup is
 * captured, checked, and evaluated here so the same bytes cross the opt-in
 * boundary; immutable embedded startup stays on Tcl_Main's source path.
 */
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "machteld.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static int host_mode = MACHTELD_HOST_NORMAL;

void
Machteld_SetHostMode(int mode)
{
    host_mode = mode;
}

int
Machteld_EntryError(Tcl_Interp *interp, const char *code, const char *message)
{
    Tcl_SetObjResult(interp, Tcl_NewStringObj(message, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "ENTRY", code, NULL);
    return TCL_ERROR;
}

static int
entry_win_error(Tcl_Interp *interp, const char *message, DWORD error)
{
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s (Windows error %lu)",
        message, (unsigned long)error));
    Tcl_SetErrorCode(interp, "MACHTELD", "ENTRY", "oserror", NULL);
    return TCL_ERROR;
}

static int
entry_detail_error(Tcl_Interp *interp, const char *code, const char *message)
{
    Tcl_Obj *detail = Tcl_DuplicateObj(Tcl_GetObjResult(interp));
    Tcl_IncrRefCount(detail);
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s: %s", message,
        Tcl_GetString(detail)));
    Tcl_DecrRefCount(detail);
    Tcl_SetErrorCode(interp, "MACHTELD", "ENTRY", code, NULL);
    return TCL_ERROR;
}

/* Read a native startup file once while writers and renames are excluded.
 * Validation and evaluation then consume the same decoded value. */
static int
capture_native_startup(Tcl_Interp *interp, Tcl_Obj *path,
                       Tcl_Obj **script_out)
{
    *script_out = NULL;
    Tcl_Obj *normalized = Tcl_FSGetNormalizedPath(interp, path);
    if (normalized == NULL) {
        return Machteld_EntryError(interp, "badvalue",
            "cannot normalize the startup program path");
    }
    Tcl_IncrRefCount(normalized);
    const void *native = Tcl_FSGetNativePath(normalized);
    if (native == NULL) {
        Tcl_DecrRefCount(normalized);
        Tcl_ResetResult(interp);
        return TCL_OK;
    }

    HANDLE handle = CreateFileW((const wchar_t *)native, GENERIC_READ,
        FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    Tcl_DecrRefCount(normalized);
    if (handle == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) {
            return Machteld_EntryError(interp, "notfound",
                "the startup program does not exist");
        }
        return entry_win_error(interp,
            "cannot open the startup program", error);
    }
    if (GetFileType(handle) != FILE_TYPE_DISK) {
        CloseHandle(handle);
        return Machteld_EntryError(interp, "badvalue",
            "the startup program is not a regular file");
    }

    LARGE_INTEGER size;
    if (!GetFileSizeEx(handle, &size)) {
        DWORD error = GetLastError();
        CloseHandle(handle);
        return entry_win_error(interp,
            "cannot size the startup program", error);
    }
    if (size.QuadPart < 0 || (ULONGLONG)size.QuadPart > (ULONGLONG)TCL_SIZE_MAX) {
        CloseHandle(handle);
        return Machteld_EntryError(interp, "badvalue",
            "the startup program is too large to evaluate");
    }

    size_t byte_count = (size_t)size.QuadPart;
    unsigned char *bytes = (unsigned char *)malloc(byte_count == 0 ? 1 : byte_count);
    if (bytes == NULL) {
        CloseHandle(handle);
        return Machteld_EntryError(interp, "oserror",
            "out of memory reading the startup program");
    }

    size_t offset = 0;
    while (offset < byte_count) {
        size_t remaining = byte_count - offset;
        DWORD request = remaining > 0x40000000u
                      ? 0x40000000u : (DWORD)remaining;
        DWORD received = 0;
        if (!ReadFile(handle, bytes + offset, request, &received, NULL)) {
            DWORD error = GetLastError();
            free(bytes);
            CloseHandle(handle);
            return entry_win_error(interp,
                "cannot read the startup program", error);
        }
        if (received == 0) {
            free(bytes);
            CloseHandle(handle);
            return Machteld_EntryError(interp, "oserror",
                "the startup program ended while it was being read");
        }
        offset += received;
    }
    if (!CloseHandle(handle)) {
        DWORD error = GetLastError();
        free(bytes);
        return entry_win_error(interp,
            "cannot close the captured startup program", error);
    }

    /* Tcl's source contract ignores a UTF-8 BOM and treats ^Z as EOF. */
    for (size_t i = 0; i < byte_count; i++) {
        if (bytes[i] == 0x1a) {
            byte_count = i;
            break;
        }
    }
    size_t start = byte_count >= 3 && bytes[0] == 0xef &&
                   bytes[1] == 0xbb && bytes[2] == 0xbf ? 3 : 0;

    Tcl_Encoding encoding = Tcl_GetEncoding(interp, "utf-8");
    if (encoding == NULL) {
        free(bytes);
        return entry_detail_error(interp, "encoding",
            "cannot load the UTF-8 decoder for the startup program");
    }
    Tcl_DString decoded;
    Tcl_DStringInit(&decoded);
    Tcl_Size error_location = 0;
    int status = Tcl_ExternalToUtfDStringEx(interp, encoding,
        (const char *)bytes + start, (Tcl_Size)(byte_count - start),
        TCL_ENCODING_START | TCL_ENCODING_END | TCL_ENCODING_PROFILE_STRICT,
        &decoded, &error_location);
    Tcl_FreeEncoding(encoding);
    free(bytes);
    if (status != TCL_OK) {
        Tcl_DStringFree(&decoded);
        return entry_detail_error(interp, "encoding",
            "the startup program is not valid UTF-8");
    }

    /* Match the default text-channel translation used by Tcl_FSEvalFileEx. */
    char *text = Tcl_DStringValue(&decoded);
    Tcl_Size length = Tcl_DStringLength(&decoded);
    Tcl_Size write = 0;
    for (Tcl_Size read = 0; read < length; read++) {
        if (text[read] == '\r') {
            if (read + 1 < length && text[read + 1] == '\n') {
                read++;
            }
            text[write++] = '\n';
        } else {
            text[write++] = text[read];
        }
    }
    *script_out = Tcl_NewStringObj(text, write);
    Tcl_IncrRefCount(*script_out);
    Tcl_DStringFree(&decoded);
    return TCL_OK;
}

static int
literal_word(const Tcl_Parse *parse, Tcl_Size wanted, const char **start,
             Tcl_Size *length)
{
    Tcl_Token *token = parse->tokenPtr;
    for (Tcl_Size word = 0; word < parse->numWords; word++) {
        if (word == wanted) {
            if (token->type != TCL_TOKEN_SIMPLE_WORD ||
                    token->numComponents != 1 ||
                    token[1].type != TCL_TOKEN_TEXT) {
                return 0;
            }
            *start = token[1].start;
            *length = token[1].size;
            return 1;
        }
        token += token->numComponents + 1;
    }
    return 0;
}

static int
word_is(const Tcl_Parse *parse, Tcl_Size word, const char *expected)
{
    const char *start;
    Tcl_Size length;
    size_t expected_len = strlen(expected);
    return literal_word(parse, word, &start, &length) &&
           length == (Tcl_Size)expected_len &&
           memcmp(start, expected, expected_len) == 0;
}

static int
has_opt_in(Tcl_Interp *interp, Tcl_Obj *script)
{
    Tcl_Size length;
    const char *bytes = Tcl_GetStringFromObj(script, &length);
    if (length >= 3 && (unsigned char)bytes[0] == 0xef &&
            (unsigned char)bytes[1] == 0xbb &&
            (unsigned char)bytes[2] == 0xbf) {
        bytes += 3;
        length -= 3;
    }

    int valid = 0;
    while (length > 0) {
        Tcl_Parse parse;
        int status = Tcl_ParseCommand(interp, bytes, length, 0, &parse);
        if (status != TCL_OK) {
            Tcl_FreeParse(&parse);
            return TCL_ERROR;
        }
        if (parse.numWords != 0) {
            if (word_is(&parse, 0, "package") && word_is(&parse, 1, "require")) {
                if (parse.numWords == 3 && word_is(&parse, 2, "machteld")) {
                    valid = 1;
                } else if (parse.numWords == 4 && word_is(&parse, 2, "machteld")) {
                    const char *unused;
                    Tcl_Size unused_len;
                    valid = literal_word(&parse, 3, &unused, &unused_len);
                } else if (parse.numWords == 5 && word_is(&parse, 2, "-exact") &&
                        word_is(&parse, 3, "machteld")) {
                    const char *unused;
                    Tcl_Size unused_len;
                    valid = literal_word(&parse, 4, &unused, &unused_len);
                }
            }
            Tcl_FreeParse(&parse);
            break;
        }
        Tcl_Size consumed = parse.commandSize;
        Tcl_FreeParse(&parse);
        if (consumed <= 0 || consumed > length) {
            break;
        }
        bytes += consumed;
        length -= consumed;
    }
    if (!valid) {
        return Machteld_EntryError(interp, "optin",
            "not a machteld program: the first executable command must be "
            "\"package require machteld\"");
    }
    return TCL_OK;
}

static int
validate_file(Tcl_Interp *interp, Tcl_Obj *path)
{
    Tcl_Channel channel = Tcl_FSOpenFileChannel(interp, path, "r", 0);
    if (channel == NULL) {
        Tcl_Obj *detail = Tcl_DuplicateObj(Tcl_GetObjResult(interp));
        Tcl_IncrRefCount(detail);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("cannot read machteld entry %s: %s",
            Tcl_GetString(path), Tcl_GetString(detail)));
        Tcl_DecrRefCount(detail);
        Tcl_SetErrorCode(interp, "MACHTELD", "ENTRY", "notfound", NULL);
        return TCL_ERROR;
    }
    if (Tcl_SetChannelOption(interp, channel, "-encoding", "utf-8") != TCL_OK) {
        Tcl_Close(NULL, channel);
        return TCL_ERROR;
    }
    if (Tcl_SetChannelOption(interp, channel, "-eofchar", "\x1a") != TCL_OK) {
        Tcl_Close(NULL, channel);
        return TCL_ERROR;
    }

    Tcl_Obj *script = Tcl_NewObj();
    Tcl_IncrRefCount(script);
    Tcl_Size count = Tcl_ReadChars(channel, script, -1, 0);
    int close_status = Tcl_Close(interp, channel);
    if (count < 0 || close_status != TCL_OK) {
        Tcl_DecrRefCount(script);
        return TCL_ERROR;
    }
    int status = has_opt_in(interp, script);
    Tcl_DecrRefCount(script);
    return status;
}

static void
append_entry_context(Tcl_Interp *interp, Tcl_Obj *path)
{
    Tcl_Size length;
    const char *name = Tcl_GetStringFromObj(path, &length);
    const int limit = 150;
    int shown = length > limit ? limit : (int)length;
    Tcl_AppendObjToErrorInfo(interp, Tcl_ObjPrintf(
        "\n    (file \"%.*s%s\" line %d)", shown, name,
        length > limit ? "..." : "", Tcl_GetErrorLine(interp)));
}

static void
promote_error_info(Tcl_Interp *interp)
{
    Tcl_Obj *options = Tcl_GetReturnOptions(interp, TCL_ERROR);
    Tcl_IncrRefCount(options);
    Tcl_Obj *key = Tcl_NewStringObj("-errorinfo", -1);
    Tcl_IncrRefCount(key);
    Tcl_Obj *error_info = NULL;
    if (Tcl_DictObjGet(NULL, options, key, &error_info) == TCL_OK &&
            error_info != NULL) {
        Tcl_SetObjResult(interp, error_info);
    }
    Tcl_DecrRefCount(key);
    Tcl_DecrRefCount(options);
}

/* Tcl_FSEvalFileEx consumes one return level after evaluating a file.  The
 * public return-options API lets captured evaluation preserve that behavior. */
static int
unwind_file_return(Tcl_Interp *interp)
{
    Tcl_Obj *options = Tcl_GetReturnOptions(interp, TCL_RETURN);
    Tcl_IncrRefCount(options);
    Tcl_Obj *level_key = Tcl_NewStringObj("-level", -1);
    Tcl_IncrRefCount(level_key);
    Tcl_Obj *level_obj = NULL;
    int level = 0;
    if (Tcl_DictObjGet(interp, options, level_key, &level_obj) != TCL_OK ||
            level_obj == NULL ||
            Tcl_GetIntFromObj(interp, level_obj, &level) != TCL_OK ||
            level < 1 ||
            Tcl_DictObjPut(interp, options, level_key,
                Tcl_NewIntObj(level - 1)) != TCL_OK) {
        Tcl_DecrRefCount(level_key);
        Tcl_DecrRefCount(options);
        return TCL_ERROR;
    }
    Tcl_DecrRefCount(level_key);
    int status = Tcl_SetReturnOptions(interp, options);
    Tcl_DecrRefCount(options);
    return status;
}

static int
eval_captured_startup(Tcl_Interp *interp, Tcl_Obj *path, Tcl_Obj *script)
{
    Tcl_Obj *query[2];
    query[0] = Tcl_NewStringObj("::info", -1);
    query[1] = Tcl_NewStringObj("script", -1);
    if (Tcl_EvalObjv(interp, 2, query, TCL_EVAL_GLOBAL) != TCL_OK) {
        return TCL_ERROR;
    }
    Tcl_Obj *prior_script = Tcl_DuplicateObj(Tcl_GetObjResult(interp));
    Tcl_IncrRefCount(prior_script);

    Tcl_Obj *words[3];
    words[0] = Tcl_NewStringObj("::info", -1);
    words[1] = Tcl_NewStringObj("script", -1);
    words[2] = path;
    Tcl_Obj *wrapper = Tcl_NewListObj(3, words);
    Tcl_IncrRefCount(wrapper);
    Tcl_AppendToObj(wrapper, ";", 1);
    Tcl_AppendObjToObj(wrapper, script);

    Tcl_ResetResult(interp);
    int status = Tcl_EvalObjEx(interp, wrapper, TCL_EVAL_GLOBAL);
    Tcl_DecrRefCount(wrapper);

    Tcl_InterpState state = Tcl_SaveInterpState(interp, status);
    Tcl_Obj *restore[3];
    restore[0] = Tcl_NewStringObj("::info", -1);
    restore[1] = Tcl_NewStringObj("script", -1);
    restore[2] = prior_script;
    int restore_status = Tcl_EvalObjv(interp, 3, restore, TCL_EVAL_GLOBAL);
    Tcl_DecrRefCount(prior_script);
    if (restore_status != TCL_OK) {
        Tcl_DiscardInterpState(state);
        return Machteld_EntryError(interp, "state",
            "cannot restore the startup script context");
    }
    status = Tcl_RestoreInterpState(interp, state);

    if (status == TCL_RETURN) {
        status = unwind_file_return(interp);
    }

    if (status == TCL_ERROR) {
        append_entry_context(interp, path);
        return TCL_ERROR;
    }
    if (status != TCL_OK) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(
            "startup program returned unexpected completion code %d", status));
        Tcl_SetErrorCode(interp, "MACHTELD", "ENTRY", "completion", NULL);
        return TCL_ERROR;
    }

    /* Tcl_Main will source this immutable empty device and then follow its
     * normal done path, including Tk's installed main loop. */
    Tcl_SetStartupScript(Tcl_NewStringObj("NUL", -1), NULL);
    return TCL_OK;
}

static int
EntryCheckCmd(void *client_data, Tcl_Interp *interp, int objc,
              Tcl_Obj *const objv[])
{
    (void)client_data;
    if (objc != 2) {
        return Machteld_EntryError(interp, "badvalue",
            "wrong # args: should be \"::machteld::EntryCheck program-file\"");
    }
    if (validate_file(interp, objv[1]) != TCL_OK) {
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, objv[1]);
    return TCL_OK;
}

static TCL_NORETURN void
write_and_exit(Tcl_Interp *interp, Tcl_Channel channel, int status)
{
    Tcl_Obj *result = Tcl_GetObjResult(interp);
    Tcl_Size length;
    const char *text = Tcl_GetStringFromObj(result, &length);
    if (channel != NULL && length != 0) {
        Tcl_WriteChars(channel, text, length);
        Tcl_WriteChars(channel, "\n", 1);
        Tcl_Flush(channel);
    }
    Tcl_Exit(status);
}

TCL_NORETURN void
Machteld_Fatal(Tcl_Interp *interp)
{
    write_and_exit(interp, Tcl_GetStdChannel(TCL_STDERR), 1);
}

static void
dispatch_command(Tcl_Interp *interp, const char *command, int with_argv)
{
    Tcl_Obj *call = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(call);
    Tcl_ListObjAppendElement(interp, call, Tcl_NewStringObj(command, -1));
    if (with_argv) {
        Tcl_Obj *argv_obj = Tcl_GetVar2Ex(interp, "argv", NULL, TCL_GLOBAL_ONLY);
        Tcl_Size objc;
        Tcl_Obj **objv;
        if (argv_obj == NULL || Tcl_ListObjGetElements(interp, argv_obj, &objc, &objv) != TCL_OK) {
            Tcl_DecrRefCount(call);
            write_and_exit(interp, Tcl_GetStdChannel(TCL_STDERR), 2);
        }
        for (Tcl_Size i = 0; i < objc; i++) {
            Tcl_ListObjAppendElement(interp, call, objv[i]);
        }
    }
    int status = Tcl_EvalObjEx(interp, call, TCL_EVAL_GLOBAL);
    Tcl_DecrRefCount(call);
    write_and_exit(interp, Tcl_GetStdChannel(
        status == TCL_OK ? TCL_STDOUT : TCL_STDERR), status == TCL_OK ? 0 : 1);
}

static int
startup_path_absent(Tcl_Obj *path)
{
    Tcl_StatBuf info;
    if (Tcl_FSStat(path, &info) == 0) {
        return 0;
    }
    int error = Tcl_GetErrno();
    return error == ENOENT || error == ENOTDIR;
}

int
Machteld_EntryGate(Tcl_Interp *interp)
{
    /* `wrap` calls the same parser used by direct startup.  Keeping this as a
     * private, capitalized command avoids a second grammar-sensitive checker. */
    if (Tcl_CreateObjCommand(interp, "::machteld::EntryCheck", EntryCheckCmd,
            NULL, NULL) == NULL) {
        return TCL_ERROR;
    }

    if (host_mode == MACHTELD_HOST_HELP) {
        dispatch_command(interp, "::machteld::help", 0);
    }
    if (host_mode == MACHTELD_HOST_VERSION) {
        dispatch_command(interp, "::machteld::version", 0);
    }
    if (host_mode == MACHTELD_HOST_STDIN) {
        Machteld_EntryError(interp, "usage",
            "stdin programs are not accepted; use an opted-in program file");
        Machteld_Fatal(interp);
    }
    if (host_mode == MACHTELD_HOST_ENCODING) {
        Machteld_EntryError(interp, "encoding",
            "the -encoding host option is not accepted; machteld programs are UTF-8");
        Machteld_Fatal(interp);
    }

    Tcl_Obj *startup = Tcl_GetStartupScript(NULL);
    if (startup == NULL) {
        Tcl_Obj *interactive = Tcl_GetVar2Ex(interp, "tcl_interactive", NULL,
                                             TCL_GLOBAL_ONLY);
        int enabled;
        if (interactive == NULL ||
                Tcl_GetBooleanFromObj(interp, interactive, &enabled) != TCL_OK) {
            Machteld_EntryError(interp, "state",
                "host did not establish a valid interactive-input state");
            Machteld_Fatal(interp);
        }
        if (!enabled) {
            Machteld_EntryError(interp, "stdin",
                "redirected stdin is not accepted; use an opted-in program file");
            Machteld_Fatal(interp);
        }
        return TCL_OK;
    }
    const char *selected = Tcl_GetString(startup);

    /* A real path always wins over the convenience `wrap` route. */
    if (strcmp(selected, "wrap") == 0 && startup_path_absent(startup)) {
        dispatch_command(interp, "::machteld::wrap", 1);
    }

    if (strcmp(selected, "-") == 0 || selected[0] == '\0') {
        Machteld_EntryError(interp, "usage",
            "stdin programs are not accepted; use an opted-in program file");
        Machteld_Fatal(interp);
    }

    Tcl_Obj *captured = NULL;
    if (capture_native_startup(interp, startup, &captured) != TCL_OK) {
        Machteld_Fatal(interp);
    }
    if (captured != NULL) {
        if (has_opt_in(interp, captured) != TCL_OK) {
            Tcl_DecrRefCount(captured);
            Machteld_Fatal(interp);
        }
        if (eval_captured_startup(interp, startup, captured) != TCL_OK) {
            Tcl_DecrRefCount(captured);
            promote_error_info(interp);
            Machteld_Fatal(interp);
        }
        Tcl_DecrRefCount(captured);
        return TCL_OK;
    }
    if (validate_file(interp, startup) != TCL_OK) {
        Machteld_Fatal(interp);
    }
    return TCL_OK;
}
