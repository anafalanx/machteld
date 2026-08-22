/* Shared initialization and entry policy for the console and GUI hosts. */
#ifndef MACHTELD_H
#define MACHTELD_H

#include "tcl.h"

#define MACHTELD_VERSION "0.12.0"

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

/*
 * Engine mode (docs/engine.md): the third face of the executable, entered
 * via the reserved host word `--machteld-engine` before any Tcl or zipfs
 * work. Runs the protocol-1 frame loop over binary stdio and never returns
 * to the Tcl hosts; the process exit code is its result. threads <= 0 asks
 * for the default (logical cores, capped).
 */
int Machteld_EngineMain(int threads);

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
