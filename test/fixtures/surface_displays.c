/* Report physical monitor bounds and effective DPI for the Tk display test.
 * This process only queries the window station. It never changes settings. */
#include <windows.h>
#include <shellscalingapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static BOOL CALLBACK report(HMONITOR monitor, HDC dc, LPRECT bounds, LPARAM selected) {
    (void)dc;
    if (selected && monitor != (HMONITOR)selected) return TRUE;
    UINT dpiX, dpiY;
    if (FAILED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY))) return FALSE;
    printf("%ld %ld %ld %ld %u %u\n", bounds->left, bounds->top, bounds->right, bounds->bottom, dpiX, dpiY);
    return TRUE;
}

int main(int argc, char **argv) {
    if (!SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) return 1;
    HMONITOR selected = NULL;
    if (argc == 2) {
        char *end;
        uintptr_t window = (uintptr_t)strtoull(argv[1], &end, 0);
        if (!window || *end || !(selected = MonitorFromWindow((HWND)window, MONITOR_DEFAULTTONULL))) return 2;
    } else if (argc != 1) return 2;
    return EnumDisplayMonitors(NULL, NULL, report, (LPARAM)selected) ? 0 : 1;
}
