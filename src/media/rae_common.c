#include "rae_common.h"
#include <stdarg.h>
#include <stdio.h>

static thread_local char diagnostic[512];

void rae_logf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(diagnostic, sizeof diagnostic, format, args);
    va_end(args);
}

const char *media_last_error(void) {
    return diagnostic;
}
