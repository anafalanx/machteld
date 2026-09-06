/* wintext.c -- strict UTF-8 <-> UTF-16 conversion; see wintext.h. */
#include "wintext.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>

wchar_t *mt_utf8_to_wide(const char *utf8) {
    if (utf8 == NULL) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (w == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, w, n) <= 0) {
        free(w);
        return NULL;
    }
    return w;
}

char *mt_wide_to_utf8(const wchar_t *wide, int count) {
    if (wide == NULL) return NULL;
    int need = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, count, NULL, 0, NULL, NULL);
    if (need <= 0) return NULL;
    /* With count == -1 the size includes the terminator; with an explicit count
     * it does not. One extra byte leaves room for NUL in both cases, and the
     * explicit terminator below makes the result a C string either way. */
    char *s = (char *)malloc((size_t)need + 1);
    if (s == NULL) return NULL;
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, count, s, need, NULL, NULL) <= 0) {
        free(s);
        return NULL;
    }
    s[need] = '\0';
    return s;
}
