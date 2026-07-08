/*
 * winjob_launch.c -- born-in-job process launch, ported from drang's launch.go.
 * The child is placed into its jobs by the kernel at CreateProcess time (the
 * PROC_THREAD_ATTRIBUTE_JOB_LIST attribute), before its first thread runs, so
 * nothing it spawns can escape supervision -- race-free, no suspend/resume dance.
 * Exactly the three stdio handles are inherited, as private duplicates; the
 * caller's handles are never mutated. Batch targets are routed through a
 * defensively quoted cmd.exe (the CVE-2024-24576 mitigation, in winjob_cmdline.c).
 */
#include "winjob.h"

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00 /* Windows 10/11: STARTUPINFOEX, ProcThreadAttribute* */
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <stdio.h>

#ifndef PROC_THREAD_ATTRIBUTE_JOB_LIST
#define PROC_THREAD_ATTRIBUTE_JOB_LIST 0x0002000D
#endif

/* ---- UTF-8 <-> UTF-16 (Tcl strings are UTF-8; Win32 wants UTF-16) ------- */

static wchar_t *u8_to_u16(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (w == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n) <= 0) {
        free(w);
        return NULL;
    }
    return w;
}

static char *u16_to_u8(const wchar_t *w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *s = (char *)malloc((size_t)n);
    if (s == NULL) return NULL;
    if (WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL) <= 0) {
        free(s);
        return NULL;
    }
    return s;
}

static int path_is_absolute(const char *p) {
    if (p == NULL || p[0] == '\0') return 0;
    if ((p[0] == '\\' || p[0] == '/') && (p[1] == '\\' || p[1] == '/')) return 1; /* UNC */
    int drive = (p[0] >= 'A' && p[0] <= 'Z') || (p[0] >= 'a' && p[0] <= 'z');
    return drive && p[1] == ':' && (p[2] == '\\' || p[2] == '/');
}

/* Resolve cmd.exe from OUR OWN environment and the system directory -- never a
 * child's custom env, which could point ComSpec at a hostile "cmd.exe" and turn
 * the batch mitigation into an execution vector of its own. Returns UTF-8. */
static char *comspec_path(const char **err) {
    wchar_t buf[1024];
    DWORD n = GetEnvironmentVariableW(L"ComSpec", buf, (DWORD)(sizeof(buf) / sizeof(buf[0])));
    if (n > 0 && n < sizeof(buf) / sizeof(buf[0])) {
        char *u = u16_to_u8(buf);
        if (u != NULL && path_is_absolute(u)) return u;
        free(u);
    }
    wchar_t sys[MAX_PATH];
    UINT m = GetSystemDirectoryW(sys, MAX_PATH);
    if (m > 0 && m < MAX_PATH) {
        wchar_t full[MAX_PATH + 16];
        lstrcpynW(full, sys, MAX_PATH);
        lstrcatW(full, L"\\cmd.exe");
        return u16_to_u8(full);
    }
    *err = "cannot locate cmd.exe to run a batch file";
    return NULL;
}

int wj_launch(const char *exe, int argc, const char *const *argv, const char *dir,
              void *const *job_handles, int njobs, const wj_stdio *io,
              int want_breakaway, int *pid, void **proc, const char **err) {
    if (exe == NULL || exe[0] == '\0') { *err = "empty exe"; return -1; }
    if (argc <= 0 || argv == NULL) { *err = "empty argv"; return -1; }
    if (io == NULL || io->in == NULL || io->out == NULL || io->err == NULL) {
        *err = "all three stdio handles must be non-NULL";
        return -1;
    }
    if (njobs <= 0 || job_handles == NULL) { *err = "at least one job is required"; return -1; }
    if (dir != NULL && dir[0] != '\0' && !path_is_absolute(exe)) {
        *err = "exe must be an absolute path when dir is set";
        return -1;
    }

    int      rc = -1;
    char    *cmdText = NULL;
    char    *comspec = NULL;
    wchar_t *wApp = NULL, *wCmd = NULL, *wDir = NULL;
    HANDLE  *jobs = NULL;
    LPPROC_THREAD_ATTRIBUTE_LIST al = NULL;
    int      alInited = 0;
    HANDLE   dups[3] = { NULL, NULL, NULL };
    HANDLE   inheritList[3];
    int      ninherit = 0;

    /* Batch targets go through cmd.exe with a defensively quoted line; PE targets
     * use the CommandLineToArgvW convention. */
    const char *appExe = exe;
    if (wj_is_batch_target(exe)) {
        comspec = comspec_path(err);
        if (comspec == NULL) goto done;
        const char *e2 = NULL;
        if (wj_make_batch_cmdline(exe, argc - 1, argv + 1, &cmdText, &e2) != 0) {
            *err = e2;
            goto done;
        }
        appExe = comspec;
    } else {
        cmdText = wj_make_cmdline(argc, argv);
    }

    wApp = u8_to_u16(appExe);
    wCmd = u8_to_u16(cmdText); /* CreateProcessW may modify this buffer: it's our own copy */
    if (wApp == NULL || wCmd == NULL) { *err = "bad executable path or command line"; goto done; }
    if (dir != NULL && dir[0] != '\0') {
        wDir = u8_to_u16(dir);
        if (wDir == NULL) { *err = "bad working directory"; goto done; }
    }

    /* Duplicate each DISTINCT stdio handle into a private, inheritable copy; we
     * never mutate the caller's handles, and only our dups can be inherited. */
    HANDLE cur = GetCurrentProcess();
    HANDLE origs[3] = { (HANDLE)io->in, (HANDLE)io->out, (HANDLE)io->err };
    for (int i = 0; i < 3; i++) {
        int prior = -1;
        for (int k = 0; k < i; k++) {
            if (origs[k] == origs[i]) { prior = k; break; }
        }
        if (prior >= 0) { dups[i] = dups[prior]; continue; } /* shared handle: dup once */
        HANDLE d = NULL;
        if (!DuplicateHandle(cur, origs[i], cur, &d, 0, TRUE, DUPLICATE_SAME_ACCESS)) {
            *err = "DuplicateHandle failed";
            goto done;
        }
        dups[i] = d;
        inheritList[ninherit++] = d;
    }

    jobs = (HANDLE *)malloc((size_t)njobs * sizeof(HANDLE));
    if (jobs == NULL) { *err = "out of memory"; goto done; }
    for (int i = 0; i < njobs; i++) {
        jobs[i] = (HANDLE)job_handles[i];
    }

    SIZE_T alSize = 0;
    InitializeProcThreadAttributeList(NULL, 2, 0, &alSize);
    al = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(alSize);
    if (al == NULL || !InitializeProcThreadAttributeList(al, 2, 0, &alSize)) {
        *err = "InitializeProcThreadAttributeList failed";
        goto done;
    }
    alInited = 1;
    /* JOB_LIST: born into the jobs at spawn time. HANDLE_LIST: restrict
     * inheritance to exactly the stdio dups. Both buffers outlive the spawn. */
    if (!UpdateProcThreadAttribute(al, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                   jobs, (size_t)njobs * sizeof(HANDLE), NULL, NULL)) {
        *err = "UpdateProcThreadAttribute(JOB_LIST) failed";
        goto done;
    }
    if (!UpdateProcThreadAttribute(al, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   inheritList, (size_t)ninherit * sizeof(HANDLE), NULL, NULL)) {
        *err = "UpdateProcThreadAttribute(HANDLE_LIST) failed";
        goto done;
    }

    STARTUPINFOEXW six;
    ZeroMemory(&six, sizeof(six));
    six.StartupInfo.cb = sizeof(six);
    six.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    six.StartupInfo.hStdInput = dups[0];
    six.StartupInfo.hStdOutput = dups[1];
    six.StartupInfo.hStdError = dups[2];
    six.lpAttributeList = al;

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));
    DWORD flags = EXTENDED_STARTUPINFO_PRESENT; /* env inherited => no CREATE_UNICODE_ENVIRONMENT yet */
    if (want_breakaway) flags |= CREATE_BREAKAWAY_FROM_JOB;
    BOOL ok = CreateProcessW(wApp, wCmd, NULL, NULL, TRUE, flags, NULL, wDir, &six.StartupInfo, &pi);
    if (!ok && want_breakaway) {
        /* the enclosing job may forbid breakaway (e.g. a CI sandbox): retry
         * without it so the daemon still starts (it then dies with machteld). */
        ok = CreateProcessW(wApp, wCmd, NULL, NULL, TRUE, flags & ~(DWORD)CREATE_BREAKAWAY_FROM_JOB,
                            NULL, wDir, &six.StartupInfo, &pi);
    }
    if (!ok) {
        static char cpErr[128];
        snprintf(cpErr, sizeof(cpErr), "CreateProcess failed (error %lu)", (unsigned long)GetLastError());
        *err = cpErr;
        goto done;
    }
    CloseHandle(pi.hThread); /* the child is already running; we never touch its thread */
    *pid = (int)pi.dwProcessId;
    *proc = (void *)pi.hProcess;
    rc = 0;

done:
    if (alInited) DeleteProcThreadAttributeList(al);
    free(al);
    free(jobs);
    for (int i = 0; i < ninherit; i++) {
        CloseHandle(inheritList[i]); /* the child holds its own inherited copies now */
    }
    free(wApp);
    free(wCmd);
    free(wDir);
    free(cmdText);
    free(comspec);
    return rc;
}

int wj_wait_timeout(void *proc, unsigned int ms, long long *code, const char **err) {
    HANDLE h = (HANDLE)proc;
    DWORD w = WaitForSingleObject(h, ms);
    if (w == WAIT_TIMEOUT) return 1;
    if (w != WAIT_OBJECT_0) { *err = "WaitForSingleObject failed"; return -1; }
    DWORD c = 0;
    if (!GetExitCodeProcess(h, &c)) { *err = "GetExitCodeProcess failed"; return -1; }
    *code = (long long)(unsigned long long)c; /* 32-bit code, untruncated */
    return 0;
}

void wj_proc_close(void *proc) {
    if (proc != NULL) {
        CloseHandle((HANDLE)proc);
    }
}
