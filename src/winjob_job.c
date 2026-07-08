/*
 * winjob_job.c -- Windows Job Object wrapper, ported from drang's winjob.go.
 * The kernel container machteld supervises processes through: die-with-parent
 * (KILL_ON_JOB_CLOSE), whole-tree kill (Terminate), resource caps, accounting.
 *
 * Single-threaded for now (the Tcl interpreter is), so no lock yet guards
 * Terminate against Close as drang's mutex does; that synchronization arrives
 * with async child events (the IOCP monitor), not with blocking `run`.
 */
#include "winjob.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>

struct wj_job {
    HANDLE handle;
    int    closed;
    int    kill_on_close;
};

wj_job *wj_job_new(int kill_on_close, const char **err) {
    HANDLE h = CreateJobObjectW(NULL, NULL); /* NULL attrs => non-inheritable handle */
    if (h == NULL) {
        *err = "CreateJobObject failed";
        return NULL;
    }
    if (kill_on_close) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
        ZeroMemory(&info, sizeof(info));
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(h, JobObjectExtendedLimitInformation, &info, sizeof(info))) {
            CloseHandle(h);
            *err = "SetInformationJobObject(KILL_ON_JOB_CLOSE) failed";
            return NULL;
        }
    }
    wj_job *j = (wj_job *)calloc(1, sizeof(*j));
    if (j == NULL) {
        CloseHandle(h);
        *err = "out of memory";
        return NULL;
    }
    j->handle = h;
    j->kill_on_close = kill_on_close;
    return j;
}

int wj_job_set_limits(wj_job *j, const wj_limits *l, const char **err) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
    ZeroMemory(&info, sizeof(info));

    /* A single LimitFlags write is authoritative, so re-assert kill_on_close
     * here -- otherwise setting a cap would silently drop die-with-parent. */
    DWORD flags = 0;
    if (j->kill_on_close) {
        flags |= JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    }
    if (l->process_memory_bytes) {
        flags |= JOB_OBJECT_LIMIT_PROCESS_MEMORY;
        info.ProcessMemoryLimit = (SIZE_T)l->process_memory_bytes;
    }
    if (l->job_memory_bytes) {
        flags |= JOB_OBJECT_LIMIT_JOB_MEMORY;
        info.JobMemoryLimit = (SIZE_T)l->job_memory_bytes;
    }
    if (l->process_cpu_100ns) {
        flags |= JOB_OBJECT_LIMIT_PROCESS_TIME;
        info.BasicLimitInformation.PerProcessUserTimeLimit.QuadPart = (LONGLONG)l->process_cpu_100ns;
    }
    if (l->job_cpu_100ns) {
        flags |= JOB_OBJECT_LIMIT_JOB_TIME;
        info.BasicLimitInformation.PerJobUserTimeLimit.QuadPart = (LONGLONG)l->job_cpu_100ns;
    }
    if (l->active_process_cap) {
        flags |= JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
        info.BasicLimitInformation.ActiveProcessLimit = (DWORD)l->active_process_cap;
    }
    info.BasicLimitInformation.LimitFlags = flags;

    if (!SetInformationJobObject(j->handle, JobObjectExtendedLimitInformation, &info, sizeof(info))) {
        *err = "SetInformationJobObject(limits) failed";
        return -1;
    }
    return 0;
}

int wj_job_assign(wj_job *j, void *process_handle, const char **err) {
    if (j->closed) {
        *err = "job is closed";
        return -1;
    }
    if (!AssignProcessToJobObject(j->handle, (HANDLE)process_handle)) {
        *err = "AssignProcessToJobObject failed";
        return -1;
    }
    return 0;
}

int wj_job_terminate(wj_job *j, unsigned int exit_code) {
    if (j->closed) {
        return 0; /* already released; nothing to terminate */
    }
    return TerminateJobObject(j->handle, (UINT)exit_code) ? 0 : -1;
}

void wj_job_close(wj_job *j) {
    if (j == NULL || j->closed) {
        return;
    }
    j->closed = 1;
    CloseHandle(j->handle);
}

void wj_job_free(wj_job *j) {
    if (j == NULL) {
        return;
    }
    wj_job_close(j);
    free(j);
}

void *wj_job_handle(wj_job *j) {
    return (void *)j->handle;
}

int wj_in_job(void *process_handle, void *job_handle) {
    BOOL res = FALSE;
    if (!IsProcessInJob((HANDLE)process_handle, (HANDLE)job_handle, &res)) {
        return -1;
    }
    return res ? 1 : 0;
}
