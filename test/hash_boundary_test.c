/* Seed the private sequence near exhaustion without billions of operations.
 * Compile this unit with Tcl's static archive and bcrypt; it includes the real
 * hash implementation, not a model or production test hook. */
#ifndef HASH_BOUNDARY_SOURCE
#define HASH_BOUNDARY_SOURCE "../src/hash.c"
#endif
#include HASH_BOUNDARY_SOURCE

int main(int argc, char **argv) {
    (void)argc;
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    Tcl_FindExecutable(argv[0]);
    Tcl_Interp *interp = Tcl_CreateInterp();
    if (Tcl_Eval(interp, "namespace eval ::machteld {}") != TCL_OK ||
            Machteldhash_Init(interp) != TCL_OK) return 2;
    Tcl_CmdInfo info;
    if (!Tcl_GetCommandInfo(interp, "::machteld::hash", &info)) return 2;
    hash_state *state = (hash_state *)info.objClientData;
    state->seq = INT_MAX - 1;
    int failures = 0;
    if (Tcl_Eval(interp, "set last [::machteld::hash start sha256]") != TCL_OK ||
            strcmp(Tcl_GetStringResult(interp), "hash#2147483647") != 0) failures++;
    int status = Tcl_Eval(interp, "::machteld::hash start sha256");
    const char *code = Tcl_GetVar(interp, "errorCode", TCL_GLOBAL_ONLY);
    if (status != TCL_ERROR || code == NULL || strcmp(code, "MACHTELD HASH oserror") != 0) failures++;
    if (state->seq != INT_MAX || state->ctxs == NULL || state->ctxs->next != NULL) failures++;
    if (Tcl_Eval(interp, "::machteld::hash update $last abc; ::machteld::hash final $last") != TCL_OK ||
            strcmp(Tcl_GetStringResult(interp), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") != 0) failures++;
    if (state->ctxs != NULL) failures++;
    if (Tcl_Eval(interp, "::machteld::hash sum sha256 abc") != TCL_OK ||
            strcmp(Tcl_GetStringResult(interp), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") != 0) failures++;
    Tcl_DeleteInterp(interp);
    Tcl_Finalize();
    printf("hash boundary: %d/6 passed; %d failures\n", 6 - failures, failures);
    return failures ? 1 : 0;
}
