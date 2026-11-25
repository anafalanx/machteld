#ifndef MACHTELD_MEDIA_COMMON_H
#define MACHTELD_MEDIA_COMMON_H
#ifndef COBJMACROS
#define COBJMACROS
#endif
#include <windows.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define RAE_URL_MAX 2048
typedef enum {
    RAE_OK, RAE_E_INVALID, RAE_E_OOM, RAE_E_FORMAT, RAE_E_DECODER,
    RAE_E_AUDIO, RAE_E_PLAYLIST, RAE_E_UNSUPPORTED
} rae_err;

/* Per-thread diagnostics from the reusable decoder and output code. */
void rae_logf(const char *format, ...);
const char *media_last_error(void);
#endif
