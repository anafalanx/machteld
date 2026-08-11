/*
 * machteld_appinit.c -- the shared per-interpreter setup for both machteld hosts.
 *
 * Everything that makes an interpreter "machteld" -- the native C libraries and
 * the Tcl prelude -- is registered here, so the console host (machteld_main.c)
 * and the GUI host (machteld_gui_main.c) share it verbatim. Adding a C library is
 * a one-line change here that both bares inherit; the hosts themselves carry only
 * their entry point and their Tk policy (on-demand for the console shell, up
 * front for the GUI host).
 */
#undef USE_TCL_STUBS
#include "machteld.h"

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
#ifdef MACHTELD_JOURNAL
extern int Machteldjournal_Init(Tcl_Interp *interp); /* src/journal.c */
#endif
#ifdef MACHTELD_HASH
extern int Machteldhash_Init(Tcl_Interp *interp); /* src/hash.c */
#endif
#ifdef MACHTELD_DIRS
extern int Machtelddirs_Init(Tcl_Interp *interp); /* src/dirs.c */
#endif

int
Machteld_RegisterLibs(Tcl_Interp *interp)
{
#ifdef MACHTELD_STATIC_SQLITE
    /* purpose-built SQLite bridge (src/store.c + the statically compiled
     * amalgamation), exposed as ::machteld::store -- no generic sqlite3, no DLL. */
    if (Machteldstore_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldstore", Machteldstore_Init, NULL);
#endif

#ifdef MACHTELD_PROC
    /* process-control substrate: the root Job Object plus run / child / wait /
     * scope / detach / pty (born-in-job, tree-kill, limits, capture). */
    if (Machteldproc_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldproc", Machteldproc_Init, NULL);
#endif

#ifdef MACHTELD_JSON
    /* JSON, hand-rolled straight into Tcl_Obj: the contract says dicts are
     * JSON-isomorphic, and Tcl 9 core ships no parser. */
    if (Machteldjson_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldjson", Machteldjson_Init, NULL);
#endif

#ifdef MACHTELD_PS
    /* the machine's processes, as distinct from the children we started:
     * enumerate, inspect, terminate by pid. */
    if (Machteldps_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldps", Machteldps_Init, NULL);
#endif

#ifdef MACHTELD_JOURNAL
    /* the front door's own record of what it started: its own connection and its
     * own file, so `store` and the journal cannot evict one another. */
    if (Machteldjournal_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldjournal", Machteldjournal_Init, NULL);
#endif
#ifdef MACHTELD_HASH
    /* digests, HMAC and cryptographic random over CNG -- the one stdlib category
     * machteld had entirely empty. */
    if (Machteldhash_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machteldhash", Machteldhash_Init, NULL);
#endif
#ifdef MACHTELD_DIRS
    /* the directory tree, in C because Tcl's glob answers differently than it
     * reads -- three prelude walkers were wrong three different ways without
     * raising anything (docs/direction.md, "cdirs does not become Tcl"). */
    if (Machtelddirs_Init(interp) == TCL_ERROR) {
        return TCL_ERROR;
    }
    Tcl_StaticLibrary(interp, "machtelddirs", Machtelddirs_Init, NULL);
#endif

    /*
     * Source the prelude (machteld.tcl) from the appended zipfs, if present. The
     * mount point is discovered from `zipfs mount` rather than hardcoded. A tool
     * packaged WITHOUT the prelude simply has no machteld.tcl -- the guard leaves
     * it be, and only the tool's own main.tcl runs.
     */
    static const char *bootstrap =
        "namespace eval ::machteld {}\n"
        "set ::machteld::prelude {}\n"
        "catch {\n"
        "  foreach _m [dict keys [zipfs mount]] {\n"
        "    if {[file exists $_m/machteld.tcl]} {\n"
        "      set ::machteld::prelude $_m/machteld.tcl; break\n"
        "    }\n"
        "  }\n"
        "}\n"
        "if {$::machteld::prelude eq {}} {\n"
        "  foreach _d {//zipfs:/app //zipfs:/} {\n"
        "    if {[file exists $_d/machteld.tcl]} {\n"
        "      set ::machteld::prelude $_d/machteld.tcl; break\n"
        "    }\n"
        "  }\n"
        "}\n"
        "if {$::machteld::prelude ne {}} {\n"
        "  uplevel #0 [list source $::machteld::prelude]\n"
        "}\n";
    return Tcl_EvalEx(interp, bootstrap, -1, TCL_EVAL_GLOBAL);
}
