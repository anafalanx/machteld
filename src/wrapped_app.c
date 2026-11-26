/* Standalone executables use the same verified application inventory as
 * .machteld archives. Only their host selection and relaunch identity differ. */
#include "machteld.h"
#include <stddef.h>
#include <stdint.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* The OS closes this handle on process exit, including Tcl's exit paths.
 * Keep writers and deleters out while zipfs reads our executable by name. */
static HANDLE pinned_image = INVALID_HANDLE_VALUE;

int
Machteld_PinWrappedImage(const wchar_t *path)
{
    pinned_image = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    return pinned_image == INVALID_HANDLE_VALUE ? TCL_ERROR : TCL_OK;
}

int
Machteld_IsWrappedHost(void)
{
    return pinned_image != INVALID_HANDLE_VALUE;
}

int
Machteld_MountWrappedImage(void)
{
    /* Read the ZIP through the same handle we hash. A renamed parent or a
     * retargeted directory junction cannot switch application generations
     * between opening the executable and Tcl mapping its appended ZIP. */
    return Machteld_MountPinnedFile(NULL, pinned_image, "app");
}

static int
image_digest(Tcl_Interp *interp, char digest[65])
{
    LARGE_INTEGER size;
    if (!GetFileSizeEx(pinned_image, &size) || size.QuadPart <= 0 ||
            (uint64_t)size.QuadPart > SIZE_MAX) {
        return Machteld_EntryError(interp, "generation", "cannot size the wrapped executable");
    }
    HANDLE mapping = CreateFileMappingW(pinned_image, NULL, PAGE_READONLY, 0, 0, NULL);
    if (mapping == NULL) {
        return Machteld_EntryError(interp, "generation", "cannot map the wrapped executable");
    }
    void *bytes = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0);
    CloseHandle(mapping);
    if (bytes == NULL) {
        return Machteld_EntryError(interp, "generation", "cannot read the wrapped executable");
    }
    int status = Machteld_SnapshotSha256(interp, bytes, (size_t)size.QuadPart, digest);
    UnmapViewOfFile(bytes);
    return status;
}

/* The Windows loader uses the PE subsystem to select console behavior. The
 * same bit selects Tk startup, including for a renamed GUI executable. */
static int
image_is_gui(void)
{
    const BYTE *base = (const BYTE *)GetModuleHandleW(NULL);
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    const IMAGE_NT_HEADERS64 *nt = (const IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
    return nt->OptionalHeader.Subsystem == IMAGE_SUBSYSTEM_WINDOWS_GUI;
}

int
Machteld_SelectWrappedApp(Tcl_Interp *interp, Tcl_Obj *root, Tcl_Obj *prefix)
{
    char digest[65];
    if (image_digest(interp, digest) != TCL_OK) return TCL_ERROR;
    Tcl_Obj *argv = Tcl_GetVar2Ex(interp, "argv", NULL, TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG);
    Tcl_Obj **words;
    Tcl_Size count;
    if (argv == NULL || Tcl_ListObjGetElements(interp, argv, &count, &words) != TCL_OK) return TCL_ERROR;
    const char *route = "--machteld-wrapped-generation";
    if (count && strcmp(Tcl_GetString(words[0]), route) == 0) {
        Tcl_Size n = 0;
        const char *expected = count >= 2 ? Tcl_GetStringFromObj(words[1], &n) : NULL;
        if (n != 64 || memcmp(expected, digest, 64) != 0) {
            return Machteld_EntryError(interp, "generation", "wrapped application generation does not match");
        }
        Tcl_Obj *tail = Tcl_NewListObj(count - 2, words + 2);
        if (!Tcl_SetVar2Ex(interp, "argv", NULL, tail, TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG) ||
                !Tcl_SetVar2Ex(interp, "argc", NULL, Tcl_NewWideIntObj(count - 2),
                    TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG)) return TCL_ERROR;
    }
    if (Tcl_ListObjAppendElement(interp, prefix, Tcl_NewStringObj(route, -1)) != TCL_OK ||
            Tcl_ListObjAppendElement(interp, prefix, Tcl_NewStringObj(digest, 64)) != TCL_OK ||
            !Tcl_SetVar2Ex(interp, "argv0", NULL, Tcl_NewStringObj(Tcl_GetNameOfExecutable(), -1),
                TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG) ||
            !Tcl_SetVar2Ex(interp, "::tcl::zipfs::wrmax", NULL, Tcl_NewIntObj(0),
                TCL_GLOBAL_ONLY | TCL_LEAVE_ERR_MSG)) return TCL_ERROR;

    Tcl_Obj *cmd[] = {Tcl_NewStringObj("::machteld::ArchiveEntry", -1),
                      Tcl_ObjPrintf("%s/app", Tcl_GetString(root))};
    for (int i = 0; i < 2; ++i) Tcl_IncrRefCount(cmd[i]);
    int status = Tcl_EvalObjv(interp, 2, cmd, TCL_EVAL_GLOBAL);
    for (int i = 0; i < 2; ++i) Tcl_DecrRefCount(cmd[i]);
    if (status != TCL_OK) return status;
    Tcl_SetStartupScript(Tcl_GetObjResult(interp), "utf-8");
    /* Tk parses the global argv when initialized. Application arguments must
     * survive byte-for-byte, even when their spellings match Tk options. */
    if (image_is_gui()) {
        status = Tcl_EvalEx(interp,
            "apply {{args count} {set ::argv {}; set ::argc 0; "
            "try {package require Tk} finally {set ::argv $args; set ::argc $count}}} "
            "$::argv $::argc", -1, TCL_EVAL_GLOBAL);
    }
    return status;
}

/* All bytes come from the full host's private basekit. Stamp the subsystem in
 * the unsigned template before the packer applies icon/version resources or
 * appends the ZIP. GUI and console wrappers share one native build. */
static int
select_subsystem(Tcl_Interp *interp, unsigned char *bytes, Tcl_Size size, int gui)
{
    IMAGE_DOS_HEADER dos;
    IMAGE_NT_HEADERS64 header;
    if (size < (Tcl_Size)sizeof(dos)) goto invalid;
    memcpy(&dos, bytes, sizeof(dos));
    if (dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < 0 ||
            size - dos.e_lfanew < (Tcl_Size)sizeof(header)) goto invalid;
    memcpy(&header, bytes + dos.e_lfanew, sizeof(header));
    if (header.Signature != IMAGE_NT_SIGNATURE ||
            header.FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
            header.FileHeader.SizeOfOptionalHeader < sizeof(header.OptionalHeader) ||
            header.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
            header.OptionalHeader.Subsystem != IMAGE_SUBSYSTEM_WINDOWS_CUI) goto invalid;
    header.OptionalHeader.Subsystem = gui ? IMAGE_SUBSYSTEM_WINDOWS_GUI : IMAGE_SUBSYSTEM_WINDOWS_CUI;
    header.OptionalHeader.CheckSum = 0;  /* Appending the ZIP changes the final image. */
    memcpy(bytes + dos.e_lfanew, &header, sizeof(header));
    return TCL_OK;
invalid:
    Tcl_SetObjResult(interp, Tcl_NewStringObj("invalid embedded wrapped-app template", -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "unsupported", NULL);
    return TCL_ERROR;
}

int
Machteld_WrapTemplate(void *root, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    int gui;
    if (objc != 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "newPath gui");
        return TCL_ERROR;
    }
    if (Tcl_GetBooleanFromObj(interp, objv[2], &gui) != TCL_OK) return TCL_ERROR;
    Tcl_Obj *path = Tcl_ObjPrintf("%s/basekit/app.exe", Tcl_GetString((Tcl_Obj *)root));
    Tcl_IncrRefCount(path);
    Tcl_Channel in = Tcl_FSOpenFileChannel(interp, path, "rb", 0);
    Tcl_DecrRefCount(path);
    if (in == NULL) return TCL_ERROR;
    Tcl_Obj *contents = Tcl_NewObj();
    Tcl_IncrRefCount(contents);
    Tcl_Size count = Tcl_ReadChars(in, contents, TCL_INDEX_NONE, 0);
    int status = Tcl_Close(interp, in);
    if (count < 0) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("cannot read embedded wrapped-app template", -1));
        Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "oserror", NULL);
        status = TCL_ERROR;
    }
    if (status == TCL_OK) {
        Tcl_Size size;
        unsigned char *bytes = Tcl_GetBytesFromObj(interp, contents, &size);
        status = bytes == NULL ? TCL_ERROR : select_subsystem(interp, bytes, size, gui);
        if (status == TCL_OK) {
            Tcl_Channel out = Tcl_FSOpenFileChannel(interp, objv[1], "WRONLY CREAT EXCL", 0600);
            status = TCL_ERROR;
            if (out != NULL) {
                if (Tcl_WriteRaw(out, (const char *)bytes, size) != size) {
                    Tcl_Close(NULL, out);
                    Tcl_SetObjResult(interp, Tcl_NewStringObj("cannot write wrapped-app template", -1));
                    Tcl_SetErrorCode(interp, "MACHTELD", "WRAP", "oserror", NULL);
                } else {
                    status = Tcl_Close(interp, out);
                }
            }
        }
    }
    Tcl_DecrRefCount(contents);
    return status;
}
