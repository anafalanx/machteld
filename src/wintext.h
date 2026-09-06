/*
 * wintext.h -- the one UTF-8 <-> UTF-16 boundary for Machteld's Win32 code.
 *
 * Tcl strings are UTF-8; Win32 wants UTF-16. Every conversion in the native
 * palette is STRICT in both directions. Without MB_ERR_INVALID_CHARS and
 * WC_ERR_INVALID_CHARS the Win32 converters substitute U+FFFD and report
 * SUCCESS -- measured, {a, D800, b} comes back as 61 ef bf bd 62 with no error
 * -- so a name Tcl is holding with an unpaired surrogate would be silently
 * rewritten and a verb would open, launch, or list a DIFFERENT object. The rule
 * in both directions is the same: a name we cannot represent is refused (NULL)
 * and the caller reports it; it is never renamed.
 *
 * Results are malloc'd and NUL-terminated; the caller frees them. This header
 * depends on nothing but the C library, so winjob_launch.c can use it too.
 */
#ifndef MACHTELD_WINTEXT_H
#define MACHTELD_WINTEXT_H

#include <stddef.h>

/* UTF-8 (NUL-terminated) -> UTF-16. NULL on invalid input or allocation failure. */
wchar_t *mt_utf8_to_wide(const char *utf8);

/* UTF-16 -> UTF-8. `count` is the number of UTF-16 units to convert, or -1 for
 * a NUL-terminated string. The result is always NUL-terminated. NULL on an
 * unpaired surrogate, a zero `count`, or allocation failure. */
char *mt_wide_to_utf8(const wchar_t *wide, int count);

#endif /* MACHTELD_WINTEXT_H */
