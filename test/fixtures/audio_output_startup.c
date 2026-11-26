/* Exercise startup failures and both owner exit orders without an endpoint.
 * The PCM ring, Windows events and aligned heap allocations are real. */
#include "audio_internal.h"
#include "media/rae_wasapi.h"
#include <assert.h>
#include <malloc.h>
#include <process.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum Scenario { ALLOCATION, RING, FIRST_EVENT, SECOND_EVENT, THREAD, OWNER_FIRST, COMMAND_FIRST };
static enum Scenario scenario;
static unsigned allocations, rings, handles, event_calls;
static void *thread_data;
static Tcl_CmdDeleteProc *delete_command;
static const char *diagnostic;

static void *allocate_output(size_t size, size_t alignment) {
    assert(alignment >= alignof(rae_ring));
    if (scenario == ALLOCATION) return NULL;
    void *p = _aligned_malloc(size, alignment);
    assert(p && (uintptr_t)p % alignment == 0);
    ++allocations;
    return p;
}
static void free_output(void *p) {
    assert(allocations == 1);
    --allocations;
    _aligned_free(p);
}
static rae_err allocate_ring(rae_ring *r, size_t count) {
    if (scenario == RING) return RAE_E_OOM;
    rae_err rc = rae_ring_init(r, count);
    if (rc == RAE_OK) ++rings;
    return rc;
}
static void free_ring(rae_ring *r) {
    if (r->buf) {assert(rings == 1); --rings;}
    rae_ring_free(r);
}
static HANDLE WINAPI create_event(LPSECURITY_ATTRIBUTES sa, BOOL reset, BOOL initial, LPCWSTR name) {
    ++event_calls;
    if ((scenario == FIRST_EVENT && event_calls == 1) ||
        (scenario == SECOND_EVENT && event_calls == 2)) return NULL;
    HANDLE h = CreateEventW(sa, reset, initial, name);
    assert(h);
    ++handles;
    return h;
}
static BOOL WINAPI close_handle(HANDLE h) {
    assert(handles > 0);
    BOOL ok = CloseHandle(h);
    assert(ok);
    --handles;
    return ok;
}
static uintptr_t start_thread(void *security, unsigned stack, unsigned (__stdcall *entry)(void *),
                              void *data, unsigned flags, unsigned *id) {
    (void)security; (void)stack; (void)entry; (void)flags; (void)id;
    if (scenario == THREAD) return 0;
    assert(scenario == OWNER_FIRST || scenario == COMMAND_FIRST);
    thread_data = data;
    return (uintptr_t)create_event(NULL, TRUE, FALSE, NULL);
}
int audio_error(Tcl_Interp *interp, const char *code, const char *message) {
    (void)interp;
    assert(!strcmp(code, "oserror"));
    diagnostic = message;
    return TCL_ERROR;
}
int audio_handle(Tcl_Interp *interp, const char *type, Tcl_ObjCmdProc *proc, void *data,
                 Tcl_CmdDeleteProc *destroy, Tcl_Command *command) {
    (void)interp; (void)type; (void)proc; (void)command;
    assert(thread_data == data);
    delete_command = destroy;
    return TCL_OK;
}

#define _aligned_malloc allocate_output
#define _aligned_free free_output
#define rae_ring_init allocate_ring
#define rae_ring_free free_ring
#define CreateEventW create_event
#define CloseHandle close_handle
#define _beginthreadex start_thread
#include "../../src/audio_output.c"

int main(int argc, char **argv) {
    (void)argc;
    Tcl_FindExecutable(argv[0]);
    Tcl_Interp *interp = Tcl_CreateInterp();
    Tcl_Obj *rate = Tcl_NewIntObj(48000), *channels = Tcl_NewIntObj(2);
    Tcl_IncrRefCount(rate);
    Tcl_IncrRefCount(channels);
    for (unsigned pass = 0; pass < 128; ++pass) {
        for (scenario = ALLOCATION; scenario <= COMMAND_FIRST; ++scenario) {
            event_calls = 0;
            thread_data = NULL;
            delete_command = NULL;
            diagnostic = NULL;
            int rc = audio_output(interp, rate, channels);
            if (scenario < OWNER_FIRST) {
                assert(rc == TCL_ERROR && !delete_command && !thread_data && diagnostic);
                const char *expected = scenario == ALLOCATION ? "out of memory creating PCM output" :
                    scenario == THREAD ? "cannot start the audio device owner" : "cannot allocate the PCM queue";
                assert(!strcmp(expected, diagnostic));
            } else {
                assert(rc == TCL_OK && delete_command && thread_data && !diagnostic);
                if (scenario == OWNER_FIRST) release_output(thread_data);
                else delete_command(thread_data);
                assert(allocations == 1 && rings == 1 && handles == 2);
                if (scenario == OWNER_FIRST) delete_command(thread_data);
                else release_output(thread_data);
            }
            assert(!allocations && !rings && !handles);
        }
    }
    Tcl_DecrRefCount(channels);
    Tcl_DecrRefCount(rate);
    Tcl_DeleteInterp(interp);
    Tcl_Finalize();
    puts("896 PCM startup/teardown checks passed (5 allocation/start failures and both owner exit orders)");
    return 0;
}
