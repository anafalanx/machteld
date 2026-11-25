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
    if (Tcl_Eval(interp, "::machteld::hash start xxh3-64") != TCL_ERROR ||
            state->ctxs != NULL || state->seq != INT_MAX) failures++;

    state->seq = 0;
    if (Tcl_Eval(interp, "set live [::machteld::hash start xxh3-64]") != TCL_OK) return 2;
    /* Reject oversized lengths before either implementation reads the buffer. */
    const unsigned char byte = 1;
    if (digest_update(interp, &state->ctxs->digest, &byte, (Tcl_Size)ULONG_MAX + 1) != TCL_ERROR ||
            digest_update(interp, &state->ctxs->digest, &byte, -1) != TCL_ERROR) failures++;
    if (Tcl_Eval(interp, "::machteld::hash update $live abc; ::machteld::hash final $live") != TCL_OK ||
            strcmp(Tcl_GetStringResult(interp), "78af5f94892f3950") != 0 || state->ctxs != NULL) failures++;
    /* Leave a CNG provider and an aligned xxHash state live across teardown. */
    if (Tcl_Eval(interp, "::machteld::hash start sha256; ::machteld::hash start xxh3-64") != TCL_OK ||
            state->ctxs == NULL || state->ctxs->next == NULL) failures++;
    Tcl_DeleteInterp(interp);
    Tcl_Finalize();
    printf("hash boundary: %d/10 passed; %d failures\n", 10 - failures, failures);
    return failures ? 1 : 0;
}
