/* Present an ordinary application window belonging to one supervised job. */
#include "winjob.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>

typedef struct {
    HWND window;
    DWORD pid, tid;
    HANDLE process;
    RECT rect, work;
    wj_window_facts facts;
} app_window;

typedef struct {
    wj_job *job;
    const wchar_t *filter;
    app_window best;
    int rank;
} window_search;

/* Hold a handle to the process throughout selection and presentation. Recheck
 * the HWND's owner before acting: windows can disappear during enumeration. */
static int still_owned(wj_job *job, const app_window *w) {
    DWORD pid = 0;
    return GetWindowThreadProcessId(w->window, &pid) == w->tid && pid == w->pid &&
           WaitForSingleObject(w->process, 0) == WAIT_TIMEOUT && wj_job_contains(job, w->process);
}

static int sample(app_window *w) {
    DWORD cloaked = 0;
    HRESULT hr = DwmGetWindowAttribute(w->window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
    /* Fail closed when DWM cannot determine the virtual-desktop state. */
    if (FAILED(hr)) return 0;
    if (!GetWindowRect(w->window, &w->rect)) return 0;
    HMONITOR monitor = MonitorFromRect(&w->rect, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info = { .cbSize = sizeof(info) };
    if (!monitor || !GetMonitorInfoW(monitor, &info)) return 0;
    w->work = info.rcWork;
    /* Require a usable patch of the window on an actual monitor. Bounding the
     * whole desktop would also include gaps between dissimilar monitors. */
    RECT overlap;
    int on_screen = IntersectRect(&overlap, &w->rect, &info.rcWork) &&
                    (LONGLONG)overlap.right - overlap.left >= 32 &&
                    (LONGLONG)overlap.bottom - overlap.top >= 24;
    w->facts.visible = IsWindowVisible(w->window) != FALSE;
    w->facts.iconic = IsIconic(w->window) != FALSE;
    w->facts.cloaked = cloaked != 0;
    w->facts.on_screen = on_screen;
    w->facts.foreground = GetForegroundWindow() == w->window;
    return 1;
}

static BOOL CALLBACK consider(HWND hwnd, LPARAM data) {
    window_search *search = (window_search *)data;
    LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
    LONG_PTR extended = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if ((style & WS_CHILD) || (extended & (WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE)) ||
            (GetWindow(hwnd, GW_OWNER) && !(extended & WS_EX_APPWINDOW))) return TRUE;
    if (search->filter) {
        wchar_t name[256];
        if (!GetClassNameW(hwnd, name, 256) ||
                CompareStringOrdinal(name, -1, search->filter, -1, TRUE) != CSTR_EQUAL) return TRUE;
    } else if (!IsWindowVisible(hwnd)) {
        return TRUE;
    }
    app_window w = { .window = hwnd };
    w.tid = GetWindowThreadProcessId(hwnd, &w.pid);
    if (!w.tid) return TRUE;
    w.process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, w.pid);
    if (!w.process) return TRUE;
    if (still_owned(search->job, &w) && sample(&w) && (search->filter || w.facts.visible)) {
        int rank = 1 + 16 * !w.facts.cloaked + 8 * w.facts.visible +
                   4 * !w.facts.iconic + 2 * w.facts.on_screen + w.facts.foreground;
        if (rank > search->rank) {
            if (search->best.process) CloseHandle(search->best.process);
            search->best = w;
            search->rank = rank;
            return TRUE;
        }
    }
    CloseHandle(w.process);
    return TRUE;
}

static int fit_size(LONGLONG size, int usable, int minimum) {
    if (size < minimum) return max(usable / 2, min(usable, minimum));
    if (size > usable) return usable;
    return (int)size;
}

static void place_window(const app_window *w) {
    int width = fit_size((LONGLONG)w->rect.right - w->rect.left,
                         w->work.right - w->work.left, 32);
    int height = fit_size((LONGLONG)w->rect.bottom - w->rect.top,
                          w->work.bottom - w->work.top, 24);
    if (width <= 0 || height <= 0) return;
    int x = max(w->work.left, min(w->rect.left, w->work.right - width));
    int y = max(w->work.top, min(w->rect.top, w->work.bottom - height));
    SetWindowPos(w->window, NULL, x, y, width, height,
                 SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_ASYNCWINDOWPOS);
}

int wj_present(wj_job *job, const wchar_t *window_class, wj_presentation *history,
               wj_window_facts *facts, const char **err) {
    *facts = (wj_window_facts){0};
    HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_ENUMERATE | DESKTOP_READOBJECTS);
    if (!desktop) return 0;
    window_search search = { .job = job, .filter = window_class };
    SetLastError(ERROR_SUCCESS);
    BOOL complete = EnumDesktopWindows(desktop, consider, (LPARAM)&search);
    DWORD error = GetLastError();
    CloseDesktop(desktop);
    app_window *w = &search.best;
    if (!complete) {
        if (w->process) CloseHandle(w->process);
        if (error == ERROR_ACCESS_DENIED) return 0;
        *err = "EnumDesktopWindows failed";
        return -1;
    }
    if (!w->process) return 0;
    if (!still_owned(job, w) || !sample(w) || (!window_class && !w->facts.visible)) goto done;
    if (!history->attention_requested && !w->facts.cloaked) {
        if (w->window != history->prepared_window || w->pid != history->prepared_pid ||
                w->tid != history->prepared_tid) {
            history->prepared_window = w->window;
            history->prepared_pid = w->pid;
            history->prepared_tid = w->tid;
            history->show_requested = 0;
            history->placement_requested = 0;
        }
        /* Queue each operation once. A slow or unresponsive application must
         * not block the caller's UI or accumulate work on every poll. */
        if ((!w->facts.visible || w->facts.iconic) && !history->show_requested && still_owned(job, w)) {
            history->show_requested = 1;
            ShowWindowAsync(w->window, SW_SHOWNOACTIVATE);
        }
        if (w->facts.visible && !w->facts.iconic && !w->facts.on_screen &&
                !history->placement_requested && still_owned(job, w)) {
            history->placement_requested = 1;
            place_window(w);
        }
        /* Read back queued placement before reporting ready. A caller can stop
         * polling at the first ready result; that result must finish the
         * one-time presentation even when the target handled the request now. */
        if (!still_owned(job, w) || !sample(w)) goto done;
        if (w->facts.visible && !w->facts.iconic && !w->facts.cloaked && w->facts.on_screen) {
            history->attention_requested = 1;
            if (!w->facts.foreground && still_owned(job, w) &&
                    !SetForegroundWindow(w->window) && still_owned(job, w)) {
                FLASHWINFO flash = {sizeof(flash), w->window, FLASHW_TRAY, 3, 0};
                FlashWindowEx(&flash);
            }
            w->facts.foreground = GetForegroundWindow() == w->window;
        }
    }
    if (still_owned(job, w)) *facts = w->facts;
done:
    CloseHandle(w->process);
    return 0;
}
