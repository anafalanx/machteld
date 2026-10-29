/* Deterministic allocation-failure injection into the production byte buffer.
 * Compile this translation unit alone: it includes winjob_cmdline.c with only
 * malloc/realloc redirected. No production allocator or global hook is added. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif
static size_t allocation, fail_at;
static void *fault_malloc(size_t n) {
    allocation++;
    return allocation == fail_at ? NULL : malloc(n);
}
static void *fault_realloc(void *p, size_t n) {
    allocation++;
    return allocation == fail_at ? NULL : realloc(p, n);
}
#define malloc fault_malloc
#define realloc fault_realloc
#include "../src/winjob_cmdline.c"
#undef malloc
#undef realloc

static unsigned total, failed;
static void check(const char *name, int ok) {
    total++;
    if (!ok) { failed++; printf("FAIL %s\n", name); }
}

static char *build(int batch, const char *arg) {
    const char *args[] = {arg, "", "tail\\"};
    if (!batch) return wj_make_cmdline(3, args);
    char *line = NULL;
    const char *error = NULL;
    int status = wj_make_batch_cmdline("C:\\space % script.cmd", 3, args, &line, &error);
    check("batch allocation errors have a diagnostic", status == 0 || (line == NULL && error != NULL));
    return line;
}

int main(void) {
#ifdef _WIN32
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
#endif
    char input[2048];
    for (size_t i = 0; i < sizeof input - 1; i++) input[i] = "\\\" %"[i % 4];
    input[sizeof input - 1] = '\0';
    for (int batch = 0; batch < 2; batch++) {
        fail_at = 0;
        allocation = 0;
        char *reference = build(batch, input);
        if (reference == NULL) return 2;
        size_t count = allocation;
        for (size_t failure = 1; failure <= count; failure++) {
            allocation = 0;
            fail_at = failure;
            char *result = build(batch, input);
            check("each injected allocation failure refuses", result == NULL);
            free(result);
        }
        allocation = 0;
        fail_at = 0;
        char *result = build(batch, input);
        check("success after allocation failures is byte-identical",
            result != NULL && strcmp(reference, result) == 0);
        free(result);
        free(reference);
    }
    printf("native command allocation: %u/%u passed; %u failed\n", total - failed, total, failed);
    return failed ? 1 : 0;
}
