/* Shared pre-initialization and library registration for both hosts. */
#undef USE_TCL_STUBS
#include <string.h>
#include <sys/stat.h>
#include "machteld.h"

#define MACHTELD_PAYLOAD_ASSOC "machteld::payload-root"

#ifdef MACHTELD_STATIC_SQLITE
extern int Machteldstore_Init(Tcl_Interp *interp); /* src/store.c */
#endif
#ifdef MACHTELD_PROC
extern int Machteldproc_Init(Tcl_Interp *interp); /* src/proc.c */
#endif
#ifdef MACHTELD_JSON
extern int Machteldjson_Init(Tcl_Interp *interp); /* src/json.c */
#endif
#ifdef MACHTELD_PS
extern int Machteldps_Init(Tcl_Interp *interp); /* src/ps.c */
#endif
#ifdef MACHTELD_HASH
extern int Machteldhash_Init(Tcl_Interp *interp); /* src/hash.c */
#endif
#ifdef MACHTELD_DIRS
extern int Machtelddirs_Init(Tcl_Interp *interp); /* src/dirs.c */
#endif
#ifdef MACHTELD_HTTP
extern int Machteldhttp_Init(Tcl_Interp *interp); /* src/http.c */
#endif
extern int Machteldpublish_Init(Tcl_Interp *interp); /* src/publish.c */

static void
payload_root_delete(void *client_data, Tcl_Interp *interp)
{
    (void)interp;
    Tcl_DecrRefCount((Tcl_Obj *)client_data);
}

static Tcl_Obj *
payload_path(Tcl_Obj *root, const char *first, const char *second)
{
    Tcl_Obj *parts[2];
    Tcl_Size count = second == NULL ? 1 : 2;

    parts[0] = Tcl_NewStringObj(first, -1);
    Tcl_IncrRefCount(parts[0]);
    if (second != NULL) {
        parts[1] = Tcl_NewStringObj(second, -1);
        Tcl_IncrRefCount(parts[1]);
    }
    Tcl_Obj *path = Tcl_FSJoinToPath(root, count, parts);
    if (path != NULL) {
        Tcl_IncrRefCount(path);
    }
    Tcl_DecrRefCount(parts[0]);
    if (second != NULL) {
        Tcl_DecrRefCount(parts[1]);
    }
    return path;
}

static int
find_payload_root(Tcl_Interp *interp, Tcl_Obj **root_out)
{
    *root_out = NULL;
    if (TclZipfs_Mount(interp, NULL, NULL, NULL) != TCL_OK) {
        return Machteld_EntryError(interp, "payload",
            "cannot query the embedded runtime payload");
    }

    Tcl_Obj *mounts = Tcl_DuplicateObj(Tcl_GetObjResult(interp));
    Tcl_IncrRefCount(mounts);
    Tcl_Size mountc;
    Tcl_Obj **mountv;
    if (Tcl_ListObjGetElements(interp, mounts, &mountc, &mountv) != TCL_OK ||
            (mountc % 2) != 0) {
        Tcl_DecrRefCount(mounts);
        return Machteld_EntryError(interp, "payload",
            "embedded runtime mount state is invalid");
    }

    const char *executable_name = Tcl_GetNameOfExecutable();
    if (executable_name == NULL || executable_name[0] == '\0') {
        Tcl_DecrRefCount(mounts);
        return Machteld_EntryError(interp, "state",
            "host executable path is unavailable");
    }
    Tcl_Obj *executable = Tcl_NewStringObj(executable_name, -1);
    Tcl_IncrRefCount(executable);

    for (Tcl_Size i = 0; i < mountc; i += 2) {
        Tcl_Size partc;
        Tcl_Obj *parts = Tcl_FSSplitPath(mountv[i], &partc);
        if (parts == NULL) {
            Tcl_DecrRefCount(executable);
            Tcl_DecrRefCount(mounts);
            return Machteld_EntryError(interp, "payload",
                "embedded runtime mount path is invalid");
        }
        Tcl_IncrRefCount(parts);
        Tcl_Obj **partv;
        Tcl_Size listed;
        int split_ok = Tcl_ListObjGetElements(interp, parts, &listed, &partv);
        int is_app = split_ok == TCL_OK && listed == partc && partc == 2 &&
                     strcmp(Tcl_GetString(partv[1]), "app") == 0;
        Tcl_DecrRefCount(parts);
        if (split_ok != TCL_OK) {
            Tcl_DecrRefCount(executable);
            Tcl_DecrRefCount(mounts);
            return Machteld_EntryError(interp, "payload",
                "embedded runtime mount path is invalid");
        }
        if (!is_app || !Tcl_FSEqualPaths(mountv[i + 1], executable)) {
            continue;
        }
        if (*root_out != NULL) {
            Tcl_DecrRefCount(*root_out);
            *root_out = NULL;
            Tcl_DecrRefCount(executable);
            Tcl_DecrRefCount(mounts);
            return Machteld_EntryError(interp, "payload",
                "embedded runtime payload mount is ambiguous");
        }
        *root_out = Tcl_DuplicateObj(mountv[i]);
        Tcl_IncrRefCount(*root_out);
    }

    Tcl_DecrRefCount(executable);
    Tcl_DecrRefCount(mounts);
    if (*root_out == NULL) {
        return Machteld_EntryError(interp, "payload",
            "the executable has no trusted embedded runtime payload");
    }
    return TCL_OK;
}

static int
require_payload_file(Tcl_Interp *interp, Tcl_Obj *root, const char *directory,
                     const char *name, const char *message)
{
    Tcl_Obj *path = payload_path(root, directory, name);
    Tcl_StatBuf info;
    int exists = path != NULL && Tcl_FSStat(path, &info) == 0 &&
                 S_ISREG(info.st_mode);
    if (path != NULL) {
        Tcl_DecrRefCount(path);
    }
    if (!exists) {
        return Machteld_EntryError(interp, "payload", message);
    }
    return TCL_OK;
}

int
Machteld_PreInit(Tcl_Interp *interp)
{
    if (Tcl_GetAssocData(interp, MACHTELD_PAYLOAD_ASSOC, NULL) != NULL) {
        return Machteld_EntryError(interp, "state",
            "runtime pre-initialization was attempted more than once");
    }

    Tcl_Obj *root;
    if (find_payload_root(interp, &root) != TCL_OK) {
        return TCL_ERROR;
    }
    if (require_payload_file(interp, root, "tcl_library", "init.tcl",
            "embedded Tcl library is missing or corrupt") != TCL_OK ||
            require_payload_file(interp, root, "tk_library", "tk.tcl",
            "embedded Tk library is missing or corrupt") != TCL_OK ||
            require_payload_file(interp, root, "machteld.tcl", NULL,
            "embedded machteld prelude is missing or corrupt") != TCL_OK) {
        Tcl_DecrRefCount(root);
        return TCL_ERROR;
    }

    Tcl_Obj *tcl_library = payload_path(root, "tcl_library", NULL);
    Tcl_Obj *tk_library = payload_path(root, "tk_library", NULL);
    if (tcl_library == NULL || tk_library == NULL ||
            Tcl_SetVar2Ex(interp, "tcl_library", NULL, tcl_library,
                          TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG) == NULL ||
            Tcl_SetVar2Ex(interp, "tk_library", NULL, tk_library,
                          TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG) == NULL) {
        if (tcl_library != NULL) {
            Tcl_DecrRefCount(tcl_library);
        }
        if (tk_library != NULL) {
            Tcl_DecrRefCount(tk_library);
        }
        Tcl_DecrRefCount(root);
        return Machteld_EntryError(interp, "state",
            "cannot pin embedded Tcl/Tk library paths");
    }
    Tcl_DecrRefCount(tcl_library);
    Tcl_DecrRefCount(tk_library);

    Tcl_SetAssocData(interp, MACHTELD_PAYLOAD_ASSOC, payload_root_delete, root);
    Tcl_ResetResult(interp);
    return TCL_OK;
}

int
Machteld_RegisterLibs(Tcl_Interp *interp)
{
    Tcl_Obj *payload_root = Tcl_GetAssocData(interp, MACHTELD_PAYLOAD_ASSOC,
                                             NULL);
    if (payload_root == NULL) {
        return Machteld_EntryError(interp, "state",
            "runtime payload was not pinned before initialization");
    }

#ifdef MACHTELD_STATIC_SQLITE
    /* Purpose-built SQLite bridge; no generic sqlite command or loadable DLL. */
    if (Machteldstore_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldstore", Machteldstore_Init, NULL);
#endif

#ifdef MACHTELD_PROC
    /* Process control backed by Windows jobs and explicit child ownership. */
    if (Machteldproc_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldproc", Machteldproc_Init, NULL);
#endif

#ifdef MACHTELD_JSON
    /* JSON conversion directly between bytes and Tcl values. */
    if (Machteldjson_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldjson", Machteldjson_Init, NULL);
#endif

#ifdef MACHTELD_PS
    /* Inspection and signalling for machine processes not owned as children. */
    if (Machteldps_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldps", Machteldps_Init, NULL);
#endif

#ifdef MACHTELD_HASH
    /* Digests, HMAC, and cryptographic random through Windows CNG. */
    if (Machteldhash_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldhash", Machteldhash_Init, NULL);
#endif
#ifdef MACHTELD_DIRS
    /* Native enumeration includes hidden entries and reports unreadable
     * branches rather than silently returning a partial tree. */
    if (Machtelddirs_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machtelddirs", Machtelddirs_Init, NULL);
#endif
#ifdef MACHTELD_HTTP
    /* HTTPS through WinHTTP, including OS certificate and proxy policy. */
    if (Machteldhttp_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldhttp", Machteldhttp_Init, NULL);
#endif

    if (Machteldpublish_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldpublish", Machteldpublish_Init, NULL);

    Tcl_Obj *prelude = payload_path(payload_root, "machteld.tcl", NULL);
    if (prelude == NULL) {
        return Machteld_EntryError(interp, "payload",
            "cannot resolve the embedded machteld prelude");
    }
    if (Tcl_FSEvalFileEx(interp, prelude, "utf-8") != TCL_OK) {
        Tcl_Obj *detail = Tcl_DuplicateObj(Tcl_GetObjResult(interp));
        Tcl_IncrRefCount(detail);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf(
            "embedded machteld prelude failed: %s", Tcl_GetString(detail)));
        Tcl_SetErrorCode(interp, "MACHTELD", "ENTRY", "payload", NULL);
        Tcl_DecrRefCount(detail);
        Tcl_DecrRefCount(prelude);
        return TCL_ERROR;
    }
    if (Tcl_SetVar2Ex(interp, "::machteld::prelude", NULL, prelude,
            TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG) == NULL) {
        Tcl_DecrRefCount(prelude);
        return Machteld_EntryError(interp, "state",
            "cannot retain the embedded machteld prelude path");
    }
    Tcl_DecrRefCount(prelude);
    return Machteld_EntryGate(interp);
}
