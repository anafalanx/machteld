/* Deliberately invalid modes prove the analysis is active. Never ship this. */
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#if defined(ANALYZER_CANARY)
int main(void) {
    int *value = malloc(sizeof *value);
    free(value);
    return *value; /* Required analyzer-use-after-free diagnostic. */
}
#else
int main(int argc, char **argv) {
#ifdef _WIN32
    /* A deliberately trapped negative test must never open a crash dialog. */
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
#endif
    if (argc == 1) { puts("native-analysis canary ready"); return 0; }
    if (strcmp(argv[1], "overflow") == 0) {
        volatile int value = INT_MAX;
        value += argc - 1;
        return value == 0;
    }
    if (strcmp(argv[1], "bounds") == 0) {
        volatile int index = argc + 4;
        volatile int values[2] = {0, 1};
        return values[index];
    }
    if (strcmp(argv[1], "heap") == 0) {
        volatile int index = argc + 4;
        volatile int *values = malloc(2 * sizeof *values);
        if (values == NULL) return 2;
        values[index] = 7;
        free((void *)values);
        return 0;
    }
    return 2;
}
#endif
