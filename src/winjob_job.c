/*
 * winjob_job.c -- Windows Job Object wrapper.
 * The kernel container machteld supervises processes through: die-with-parent
 * (KILL_ON_JOB_CLOSE), whole-tree kill (Terminate), resource caps, accounting.
 */
#include "winjob.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>

struct wj_job {
    HANDLE handle;
    int    closed;
    int    kill_on_close;
    int    breakaway;      /* BREAKAWAY_OK granted; re-asserted by every limits write */
    CRITICAL_SECTION lock;
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
    InitializeCriticalSection(&j->lock);
    return j;
}

int wj_job_set_limits(wj_job *j, const wj_limits *l, const char **err) {
    if (j == NULL || l == NULL) {
        if (err) *err = "job is closed or limits are NULL";
        return -1;
    }
    EnterCriticalSection(&j->lock);
    if (j->closed) {
        LeaveCriticalSection(&j->lock);
        if (err) *err = "job is closed";
        return -1;
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
    ZeroMemory(&info, sizeof(info));

    /* A single LimitFlags write is authoritative, so re-assert kill_on_close
     * here -- otherwise setting a cap would silently drop die-with-parent. */
    DWORD flags = 0;
    if (j->kill_on_close) {
        flags |= JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    }
    if (j->breakaway) {
        flags |= JOB_OBJECT_LIMIT_BREAKAWAY_OK;
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
        LeaveCriticalSection(&j->lock);
        if (err) *err = "SetInformationJobObject(limits) failed";
        return -1;
    }
    LeaveCriticalSection(&j->lock);
    return 0;
}

int wj_job_allow_breakaway(wj_job *j, const char **err) {
    if (j == NULL) {
        if (err) *err = "job is closed";
        return -1;
    }
    EnterCriticalSection(&j->lock);
    if (j->closed) {
        LeaveCriticalSection(&j->lock);
        if (err) *err = "job is closed";
        return -1;
    }
    /* Start from the job's current limits: a single LimitFlags write is
     * authoritative, and a zeroed block would silently drop every cap that
     * wj_job_set_limits had installed. */
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
    ZeroMemory(&info, sizeof(info));
    DWORD got = 0;
    if (!QueryInformationJobObject(j->handle, JobObjectExtendedLimitInformation, &info, sizeof(info), &got)) {
        LeaveCriticalSection(&j->lock);
        if (err) *err = "QueryInformationJobObject(limits) failed";
        return -1;
    }
    info.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_BREAKAWAY_OK;
    if (j->kill_on_close) {
        info.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; /* preserve die-with-parent */
    }
    if (!SetInformationJobObject(j->handle, JobObjectExtendedLimitInformation, &info, sizeof(info))) {
        LeaveCriticalSection(&j->lock);
        if (err) *err = "SetInformationJobObject(BREAKAWAY_OK) failed";
        return -1;
    }
    j->breakaway = 1;
    LeaveCriticalSection(&j->lock);
    return 0;
}

int wj_job_terminate(wj_job *j, unsigned int exit_code) {
    if (j == NULL) return -1;
    EnterCriticalSection(&j->lock);
    int rc = j->closed || !TerminateJobObject(j->handle, (UINT)exit_code) ? -1 : 0;
    LeaveCriticalSection(&j->lock);
    return rc;
}

int wj_job_active(wj_job *j, unsigned int *active, const char **err) {
    if (j == NULL) {
        if (err) *err = "job is closed";
        return -1;
    }
    EnterCriticalSection(&j->lock);
    if (j->closed) {
        LeaveCriticalSection(&j->lock);
        if (err) *err = "job is closed";
        return -1;
    }
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
    ZeroMemory(&info, sizeof(info));
    if (!QueryInformationJobObject(j->handle, JobObjectBasicAccountingInformation,
                                   &info, sizeof(info), NULL)) {
        LeaveCriticalSection(&j->lock);
        if (err) *err = "QueryInformationJobObject(accounting) failed";
        return -1;
    }
    if (active) *active = (unsigned int)info.ActiveProcesses;
    LeaveCriticalSection(&j->lock);
    return 0;
}

void wj_job_close(wj_job *j) {
    if (j == NULL) return;
    EnterCriticalSection(&j->lock);
    if (!j->closed) {
        j->closed = 1;
        CloseHandle(j->handle);
    }
    LeaveCriticalSection(&j->lock);
}

void wj_job_free(wj_job *j) {
    if (j == NULL) {
        return;
    }
    wj_job_close(j);
    DeleteCriticalSection(&j->lock);
    free(j);
}

void *wj_job_handle(wj_job *j) {
    if (j == NULL) return NULL;
    EnterCriticalSection(&j->lock);
    void *h = j->closed ? NULL : (void *)j->handle;
    LeaveCriticalSection(&j->lock);
    return h;
}

