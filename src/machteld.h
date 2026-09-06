/* Shared initialization and entry policy for the console and GUI hosts. */
#ifndef MACHTELD_H
#define MACHTELD_H

#include <string.h>
#include "tcl.h"

#define MACHTELD_VERSION "0.21"

/* The byte rule shared by every value-consuming native verb -- hash, store put,
 * http post, run/child -stdin: a byte array is its bytes exactly; any other
 * value is its UTF-8 -- the real encoding, the bytes `encoding convertto utf-8`
 * produces, NOT the string representation. Tcl's internal representation is a
 * modified UTF-8 that spells U+0000 as the two bytes C0 80 (so a C string can
 * carry it); 0.20's hash and store handed those bytes on, and a string
 * containing NUL hashed and stored differently from its UTF-8. Read what the
 * value IS, never what its text looks like.
 *
 * MATCHED BY TYPE NAME, NOT BY TYPE POINTER. Tcl 9 carries two byte-array
 * object types and registers only one of them under the name "bytearray", so
 * comparing typePtr against Tcl_GetObjType("bytearray") returns false for the
 * values `binary decode` actually produces -- and the failure is silent: the
 * bytes fall through to the string path and each one is re-read as a character.
 * Tcl_GetBytesFromObj cannot be the test either: it is a coercion, not a
 * predicate, and happily converts the string "cafe<e9>" to Latin-1 bytes.
 *
 * `scratch` receives the encoded bytes when a conversion was needed; release
 * it with Tcl_DStringFree once the bytes are no longer in use (for a byte
 * array it stays empty and the pointer refers into the value). The encoder
 * runs with Tcl's tcl8 profile, the one channels write with by default, so it
 * cannot fail: an unpaired surrogate goes out as Tcl itself would write it,
 * never as an error this rule has no way to report. */
static inline const unsigned char *
Machteld_ValueBytes(Tcl_Obj *value, Tcl_Size *length, Tcl_DString *scratch)
{
    Tcl_DStringInit(scratch);
    const Tcl_ObjType *type = value->typePtr;
    if (type != NULL && type->name != NULL &&
            strcmp(type->name, "bytearray") == 0) {
        unsigned char *bytes = Tcl_GetBytesFromObj(NULL, value, length);
        if (bytes != NULL) {
            return bytes;
        }
    }
    Tcl_Size chars = 0;
    const char *text = Tcl_GetStringFromObj(value, &chars);
    Tcl_Encoding utf8 = Tcl_GetEncoding(NULL, "utf-8");
    Tcl_UtfToExternalDStringEx(NULL, utf8, text, chars,
                               TCL_ENCODING_PROFILE_TCL8, scratch, NULL);
    Tcl_FreeEncoding(utf8);
    *length = Tcl_DStringLength(scratch);
    return (const unsigned char *)Tcl_DStringValue(scratch);
}

/* Locate and pin the script libraries in the executable's own zipfs mount.
 * Called by each host before Tcl_Init (and therefore before Tk_Init). */
int Machteld_PreInit(Tcl_Interp *interp);

/* Register the statically-linked native libraries and source the Tcl prelude
 * from the payload retained by Machteld_PreInit. */
int Machteld_RegisterLibs(Tcl_Interp *interp);

/*
 * Validate or dispatch the program Tcl_Main selected.  This runs from AppInit,
 * after the machteld package has been registered but before Tcl_Main evaluates
 * a user entry file.  It is the opt-in boundary for direct script execution.
 */
int Machteld_EntryGate(Tcl_Interp *interp);
int Machteld_EntryError(Tcl_Interp *interp, const char *code,
                        const char *message);
TCL_NORETURN void Machteld_Fatal(Tcl_Interp *interp);

enum {
    MACHTELD_HOST_NORMAL = 0,
    MACHTELD_HOST_HELP,
    MACHTELD_HOST_VERSION,
    MACHTELD_HOST_DOCS,
    MACHTELD_HOST_DOCS_GUI,
    MACHTELD_HOST_STDIN,
    MACHTELD_HOST_ENCODING
};
void Machteld_SetHostMode(int mode);
int Machteld_GetHostMode(void);

#endif /* MACHTELD_H */
