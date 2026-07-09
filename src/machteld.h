/*
 * machteld.h -- the shared surface between machteld's two hosts.
 *
 * The console host (machteld_main.c: wmain -> Tcl_Main) and the GUI host
 * (machteld_gui_main.c: WinMain -> Tk_Main) differ ONLY in their entry point and
 * PE subsystem. Every native library and the prelude bootstrap live behind
 * Machteld_RegisterLibs (machteld_appinit.c), so a new C library is added in ONE
 * place and BOTH bares pick it up -- no per-subsystem duplication.
 */
#ifndef MACHTELD_H
#define MACHTELD_H

#include "tcl.h"

/* Register machteld's statically-linked native libraries (the SQLite store, the
 * process-control substrate, and anything added later) and source the Tcl
 * prelude from the appended zipfs. Called from each host's AppInit once Tcl
 * (and, for the GUI host, Tk) are initialized. Returns TCL_OK / TCL_ERROR. */
int Machteld_RegisterLibs(Tcl_Interp *interp);

#endif /* MACHTELD_H */
