/*
 * winjob_cmdline.c -- Windows command-line quoting for machteld's process
 * launcher, including defensive batch-file quoting for CVE-2024-24576.
 */

#include "winjob.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ---- small growable byte buffer ---------------------------------------- */

typedef struct {
    char  *p;
    size_t len;
    size_t cap;
    int    failed;
} sb_t;

static int sb_init(sb_t *b) {
    b->cap = 64;
    b->len = 0;
    b->failed = 0;
    b->p = (char *)malloc(b->cap);
    if (b->p == NULL) {
        b->cap = 0;
        b->failed = 1;
        return -1;
    }
    b->p[0] = '\0';
    return 0;
}

static int sb_ensure(sb_t *b, size_t extra) {
    if (b->failed) return -1;
    if (extra > SIZE_MAX - b->len - 1) {
        b->failed = 1;
        return -1;
    }
    size_t need = b->len + extra + 1;
    if (need > b->cap) {
        size_t cap = b->cap;
        while (cap < need) {
            if (cap > SIZE_MAX / 2) { cap = need; break; }
            cap *= 2;
        }
        char *p = (char *)realloc(b->p, cap);
        if (p == NULL) {
            b->failed = 1;
            return -1;
        }
        b->p = p;
        b->cap = cap;
    }
    return 0;
}

static int sb_putc(sb_t *b, char c) {
    if (sb_ensure(b, 1) != 0) return -1;
    b->p[b->len++] = c;
    b->p[b->len] = '\0';
    return 0;
}

static int sb_puts(sb_t *b, const char *s) {
    size_t n = strlen(s);
    if (sb_ensure(b, n) != 0) return -1;
    memcpy(b->p + b->len, s, n);
    b->len += n;
    b->p[b->len] = '\0';
    return 0;
}

static char *xstrdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *r = (char *)malloc(n);
    if (r != NULL) memcpy(r, s, n);
    return r;
}

/* ---- EscapeArg (the CommandLineToArgvW convention) --------------------- *
 *
 * Faithful port of Go's syscall.EscapeArg: quote only when the argument is
 * empty, or contains a space/tab; backslashes are doubled only when they
 * precede a double-quote or the closing quote; embedded quotes become \".
 */
char *wj_escape_arg(const char *s) {
    if (s == NULL) return NULL;
    size_t len = strlen(s);
    if (len == 0) {
        return xstrdup("\"\"");
    }

    int    hasSpace = 0;
    size_t growth   = 0;
    for (size_t i = 0; i < len; i++) {
        char c = s[i];
        if (c == '"' || c == '\\') {
            growth++;
        } else if (c == ' ' || c == '\t') {
            hasSpace = 1;
        }
    }
    if (growth == 0 && !hasSpace) {
        return xstrdup(s); /* nothing to escape or wrap */
    }

    sb_t b;
    if (sb_init(&b) != 0) return NULL;
    if (hasSpace) {
        sb_putc(&b, '"');
    }
    int slashes = 0;
    for (size_t i = 0; i < len; i++) {
        char c = s[i];
        if (c == '\\') {
            slashes++;
            sb_putc(&b, '\\');
        } else if (c == '"') {
            for (; slashes > 0; slashes--) {
                sb_putc(&b, '\\'); /* double the run preceding the quote */
            }
            sb_putc(&b, '\\'); /* escape the quote itself */
            sb_putc(&b, '"');
        } else {
            slashes = 0;
            sb_putc(&b, c);
        }
    }
    if (hasSpace) {
        for (; slashes > 0; slashes--) {
            sb_putc(&b, '\\'); /* double the trailing run before the close quote */
        }
        sb_putc(&b, '"');
    }
    if (b.failed) { free(b.p); return NULL; }
    return b.p;
}

char *wj_make_cmdline(int argc, const char *const *argv) {
    if (argc < 0 || (argc > 0 && argv == NULL)) return NULL;
    sb_t b;
    if (sb_init(&b) != 0) return NULL;
    for (int i = 0; i < argc; i++) {
        if (i > 0) {
            sb_putc(&b, ' ');
        }
        char *e = wj_escape_arg(argv[i]);
        if (e == NULL || sb_puts(&b, e) != 0) {
            free(e);
            free(b.p);
            return NULL;
        }
        free(e);
    }
    if (b.failed) { free(b.p); return NULL; }
    return b.p;
}

/* ---- batch detection --------------------------------------------------- */

static int ci_eq(const char *a, const char *b) {
    while (*a && *b) {
        char ca = *a, cb = *b;
        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb + 32);
        if (ca != cb) return 0;
        a++;
        b++;
    }
    return *a == '\0' && *b == '\0';
}

/* True if the last path component's extension is .bat or .cmd. Matches Go's
 * filepath.Ext (the last '.' in the final path element). */
int wj_is_batch_target(const char *exe) {
    const char *base = exe;
    for (const char *c = exe; *c; c++) {
        if (*c == '/' || *c == '\\') base = c + 1;
    }
    /* Win32 drops trailing dots and spaces when it opens a name, so "x.bat."
     * runs x.bat: classify the name the way it will be opened. */
    size_t n = strlen(base);
    while (n > 0 && (base[n - 1] == '.' || base[n - 1] == ' ')) n--;
    if (n < 4) return 0;
    const char *ext = base + n - 4;
    return _strnicmp(ext, ".bat", 4) == 0 || _strnicmp(ext, ".cmd", 4) == 0;
}

/* ---- batch command line (CVE-2024-24576 mitigation) -------------------- *
 *
 * cmd.exe re-parses the /c payload with rules EscapeArg does not satisfy: an
 * embedded quote can close cmd's quoting, after which & | < > become live
 * operators -- arbitrary command execution. So the script and each argument are
 * individually quoted, embedded quotes are DOUBLED ("") -- cmd's literal-quote
 * convention -- with backslash runs doubled so the batch's own argv parse still
 * round-trips, and every '%' is rewritten `%%cd:~,%` (a zero-length substring of
 * the always-present %cd%) so cmd cannot expand %VAR% out of the text.
 */

/* Append s with every '%' neutralized to `%%cd:~,%`. Used for the script path,
 * which is quoted verbatim (its '"' and trailing '\' are rejected up front, so
 * it needs no backslash/quote doubling -- only '%' neutralization). */
static void append_neutralized(sb_t *b, const char *s) {
    for (size_t i = 0; s[i]; i++) {
        if (s[i] == '%') {
            sb_puts(b, "%%cd:~,");
        }
        sb_putc(b, s[i]);
    }
}

/* ASCII symbols that do NOT force an argument to be quoted; every other
 * non-alphanumeric ASCII char (and any control char) does. Rust's conservative
 * "quote unless known-safe" allowlist. */
static const char *BATCH_UNQUOTED = "#$*+-./:?@\\_";

static int is_ascii_alnum(unsigned char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

/* Append arg to b using Rust's std::process batch-argument quoting (the caller
 * has already rejected NUL / CR / LF). */
static void append_batch_arg(sb_t *b, const char *arg) {
    size_t len = strlen(arg);

    int quote = (len == 0) || (arg[len - 1] == '\\');
    if (!quote) {
        for (size_t i = 0; i < len; i++) {
            unsigned char c = (unsigned char)arg[i];
            int asciiNeedsQuote =
                (c < 0x80) && !(is_ascii_alnum(c) || (c != 0 && strchr(BATCH_UNQUOTED, c) != NULL));
            int isControl = (c < 0x20) || (c == 0x7f);
            if (asciiNeedsQuote || isControl) {
                quote = 1;
                break;
            }
        }
    }

    if (quote) {
        sb_putc(b, '"');
    }
    /* '\\' '"' '%' '\r' are ASCII and never appear inside a UTF-8 multibyte
     * sequence, so this byte walk matches Rust's UTF-16 walk for the characters
     * it acts on; other bytes pass through unchanged. */
    int backslashes = 0;
    for (size_t i = 0; i < len; i++) {
        char c = arg[i];
        if (c == '\\') {
            backslashes++;
        } else {
            if (c == '"') {
                for (int k = 0; k < backslashes; k++) {
                    sb_putc(b, '\\'); /* double the preceding run to 2n... */
                }
                sb_putc(b, '"'); /* ...then double the quote to escape it */
            } else if (c == '%' || c == '\r') {
                sb_puts(b, "%%cd:~,");
            }
            backslashes = 0;
        }
        sb_putc(b, c);
    }
    if (quote) {
        for (int k = 0; k < backslashes; k++) {
            sb_putc(b, '\\'); /* double the trailing run before the close quote */
        }
        sb_putc(b, '"');
    }
}

static int has_cr_or_lf(const char *s) {
    return strchr(s, '\r') != NULL || strchr(s, '\n') != NULL;
}

int wj_make_batch_cmdline(const char *script, int argc, const char *const *args,
                          char **out, const char **err) {
    if (out != NULL) *out = NULL;
    if (script == NULL || out == NULL || err == NULL || argc < 0 ||
        (argc > 0 && args == NULL)) {
        if (err != NULL) *err = "invalid batch command-line input";
        return -1;
    }
    size_t slen = strlen(script);
    if (strchr(script, '"') != NULL || (slen > 0 && script[slen - 1] == '\\')) {
        *err = "batch script path may not contain a quote or end with a backslash";
        return -1;
    }
    if (has_cr_or_lf(script)) {
        /* cmd truncates its line at a bare CR/LF, which could drop the closing
         * quotes and leave trailing text live -- reject it, as arguments are. */
        *err = "batch script path may not contain a carriage return or newline";
        return -1;
    }

    sb_t b;
    if (sb_init(&b) != 0) {
        *err = "out of memory";
        return -1;
    }
    sb_puts(&b, "cmd.exe /e:ON /v:OFF /d /c \""); /* opens the outer /c quote */
    sb_putc(&b, '"');                             /* opens the script's own quote */
    append_neutralized(&b, script);
    sb_putc(&b, '"'); /* closes the script's quote */

    for (int i = 0; i < argc; i++) {
        const char *a = args[i];
        if (has_cr_or_lf(a)) {
            free(b.p);
            *err = "batch argument may not contain a carriage return or newline";
            return -1;
        }
        sb_putc(&b, ' ');
        append_batch_arg(&b, a);
        if (b.failed) {
            free(b.p);
            *err = "out of memory";
            return -1;
        }
    }
    sb_putc(&b, '"'); /* closes the outer /c quote */

    if (b.failed) {
        free(b.p);
        *err = "out of memory";
        return -1;
    }

    *out = b.p;
    return 0;
}
