/*
 * winjob.h -- machteld's Windows process-supervision substrate, ported from
 * drang's internal/winjob (Go). A child is launched born-in-job (assigned to
 * its jobs by the kernel at CreateProcess time, before its first thread runs --
 * race-free), giving die-with-parent, whole-tree kill, resource limits, and an
 * event stream without a reaper side-car.
 *
 * This header is filled in per increment. First: command-line quoting -- the
 * security-critical, purely-string part (no Win32), verified against drang's
 * golden vectors before anything builds on it.
 */
#ifndef MACHTELD_WINJOB_H
#define MACHTELD_WINJOB_H

#include <stddef.h>

/* ---- command-line quoting (winjob_cmdline.c) --------------------------- *
 *
 * Windows has no argv: a process receives one command-line STRING and parses
 * it back to argv itself. For a normal (PE) target the child uses the
 * CommandLineToArgvW convention, so we quote with the identical rules
 * (wj_escape_arg / wj_make_cmdline) and the child parses back the exact argv we
 * intended -- no shell, no word-splitting.
 *
 * A batch script (.bat/.cmd) is NOT a PE image: CreateProcess runs it by handing
 * the command line to cmd.exe, whose parsing differs, so an EscapeArg command
 * line is exploitable (CVE-2024-24576, "BatBadBut"). Batch targets are launched
 * through an explicitly, defensively quoted cmd.exe instead
 * (wj_make_batch_cmdline).
 *
 * All returned strings are malloc'd, NUL-terminated; the caller frees them.
 */

/* Quote one argument by the CommandLineToArgvW rules (Go's syscall.EscapeArg). */
char *wj_escape_arg(const char *arg);

/* Build a command line from argv[0..argc): each argument EscapeArg-quoted and
 * space-joined. For non-batch (PE) targets. */
char *wj_make_cmdline(int argc, const char *const *argv);

/* True if exe's final path component ends in .bat or .cmd (case-insensitive). */
int wj_is_batch_target(const char *exe);

/*
 * Build a `cmd.exe /e:ON /v:OFF /d /c "<script> <args...>"` command line that
 * runs a batch script safely (the CVE-2024-24576 mitigation, ported from Rust's
 * std::process via drang). `args` are the script's arguments (argv[1:]).
 *
 * On success: returns 0, sets *out to a malloc'd command line (caller frees).
 * On a value that cannot be made safe (a quote or trailing backslash in the
 * script path, or a CR/NL anywhere): returns -1, sets *err to a static message,
 * and does not allocate *out.
 *
 * NOTE: embedded-NUL rejection is enforced at the Tcl boundary (length-aware),
 * since these C-string entry points cannot carry an embedded NUL.
 */
int wj_make_batch_cmdline(const char *script, int argc, const char *const *args,
                          char **out, const char **err);

/* ---- Job Objects (winjob_job.c) ---------------------------------------- *
 *
 * A Job Object is the kernel container machteld supervises processes through:
 * die-with-parent (KILL_ON_JOB_CLOSE), whole-tree kill (Terminate), and
 * resource caps. HANDLEs cross this API as void* so winjob.h stays Win32-free
 * (the cmdline unit test includes it without <windows.h>).
 */
typedef struct wj_job wj_job;

/* Resource caps; a zero field means "no cap". Memory is commit bytes; CPU is
 * USER cpu time in 100ns ticks (wall-clock timeouts are the caller's job). */
typedef struct {
    unsigned long long process_memory_bytes; /* JOB_OBJECT_LIMIT_PROCESS_MEMORY */
    unsigned long long job_memory_bytes;      /* JOB_OBJECT_LIMIT_JOB_MEMORY */
    unsigned long long process_cpu_100ns;     /* JOB_OBJECT_LIMIT_PROCESS_TIME */
    unsigned long long job_cpu_100ns;         /* JOB_OBJECT_LIMIT_JOB_TIME */
    unsigned int       active_process_cap;    /* JOB_OBJECT_LIMIT_ACTIVE_PROCESS */
} wj_limits;

/* Create a Job Object. If kill_on_close, closing the last handle terminates
 * every process still in the job -- the die-with-parent guarantee. The handle is
 * non-inheritable so no child can pin the job open and defeat it. Returns NULL
 * and sets *err on failure. */
wj_job *wj_job_new(int kill_on_close, const char **err);

/* Apply caps in a SINGLE write that re-asserts kill_on_close (so a limit write
 * never drops die-with-parent). Call once, before the child is launched. */
int wj_job_set_limits(wj_job *j, const wj_limits *l, const char **err);

/* Add an already-running process to the job (how the root job takes in machteld
 * itself; the born-in-job launcher does not need this). */
int wj_job_assign(wj_job *j, void *process_handle, const char **err);

/* Kill every process in the job and its nested child jobs -- whole-tree kill. */
int wj_job_terminate(wj_job *j, unsigned int exit_code);

/* Release machteld's handle (triggers die-with-parent for a kill_on_close job).
 * Idempotent. wj_job_free also frees the struct. */
void wj_job_close(wj_job *j);
void wj_job_free(wj_job *j);

/* Raw job handle (as void*), for the launcher's born-in-job attribute list. */
void *wj_job_handle(wj_job *j);

/* Allow children of this job to break away from it (CREATE_BREAKAWAY_FROM_JOB),
 * so `detach` can hand a daemon to the OS that outlives machteld. Re-asserts the
 * job's existing kill-on-close flag. */
int wj_job_allow_breakaway(wj_job *j, const char **err);

/* Is process a member of job? 1 yes, 0 no, -1 on error. A NULL job asks whether
 * the process is in ANY job. Used to prove born-in-job membership. */
int wj_in_job(void *process_handle, void *job_handle);

/* ---- born-in-job launch (winjob_launch.c) ------------------------------ */

/* The child's three standard handles. All must be non-NULL concrete handles;
 * the caller picks inheritance, a pipe end, or the null device. */
typedef struct {
    void *in;
    void *out;
    void *err;
} wj_stdio;

/* Launch exe as a child born into the given jobs (root-first) at CreateProcess
 * time -- before its first thread runs, so nothing it spawns escapes those jobs.
 * exe is a resolved path (no PATH search), absolute when dir is set; argv is what
 * the child sees. dir=NULL inherits our cwd. Exactly the three stdio handles are
 * inherited (as private duplicates) and the caller's handles are never mutated.
 * Batch targets (.bat/.cmd) are routed through a defensively quoted cmd.exe.
 * On success sets *pid and *proc (a process HANDLE the caller waits then closes)
 * and returns 0; on failure returns -1 and sets *err. Env is inherited for now.
 * want_breakaway adds CREATE_BREAKAWAY_FROM_JOB (for detach); if the enclosing
 * job forbids it the launch retries without, so the child still starts. */
int wj_launch(const char *exe, int argc, const char *const *argv, const char *dir,
              void *const *job_handles, int njobs, const wj_stdio *io,
              int want_breakaway, int *pid, void **proc, const char **err);

/* Wait up to ms for the child (WJ_INFINITE = forever). Returns 0 and sets *code
 * on exit (the 32-bit exit code, untruncated), 1 on timeout (child still runs),
 * -1 on error (sets *err). Does not close the handle. */
#define WJ_INFINITE 0xFFFFFFFFu
int wj_wait_timeout(void *proc, unsigned int ms, long long *code, const char **err);

/* Close a process handle returned by wj_launch. */
void wj_proc_close(void *proc);

#endif /* MACHTELD_WINJOB_H */
