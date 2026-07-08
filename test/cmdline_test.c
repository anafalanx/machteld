/* cmdline_test.c -- verifies winjob_cmdline.c against drang's golden vectors
 * (internal/winjob/batch_test.go). Pure and standalone:
 *   gcc -std=c23 -Isrc test/cmdline_test.c src/winjob_cmdline.c -o cmdline_test
 */
#include "winjob.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0, total = 0;

static char *cat(const char *a, const char *b) {
    size_t na = strlen(a), nb = strlen(b);
    char *r = (char *)malloc(na + nb + 1);
    memcpy(r, a, na);
    memcpy(r + na, b, nb);
    r[na + nb] = '\0';
    return r;
}

static void batch_ok(const char *name, const char *script, int argc,
                     const char *const *args, const char *pre, const char *suffix) {
    char *got = NULL; const char *err = NULL;
    int rc = wj_make_batch_cmdline(script, argc, args, &got, &err);
    char *want = cat(pre, suffix);
    total++;
    if (rc != 0) { fails++; printf("FAIL %s (unexpected reject: %s)\n", name, err ? err : "?"); }
    else if (strcmp(got, want) != 0) { fails++; printf("FAIL %s\n  got  [%s]\n  want [%s]\n", name, got, want); }
    else printf("ok   %s\n", name);
    free(got); free(want);
}

static void batch_reject(const char *name, const char *script, int argc, const char *const *args) {
    char *got = NULL; const char *err = NULL;
    int rc = wj_make_batch_cmdline(script, argc, args, &got, &err);
    total++;
    if (rc == 0) { fails++; printf("FAIL %s (expected reject, got [%s])\n", name, got); free(got); }
    else printf("ok   %s (rejected: %s)\n", name, err);
}

static void esc(const char *name, const char *in, const char *want) {
    char *got = wj_escape_arg(in);
    total++;
    if (strcmp(got, want) != 0) { fails++; printf("FAIL escape %s\n  got  [%s]\n  want [%s]\n", name, got, want); }
    else printf("ok   escape %s\n", name);
    free(got);
}

static void bt(const char *exe, int want) {
    int got = wj_is_batch_target(exe);
    total++;
    if ((got != 0) != (want != 0)) { fails++; printf("FAIL is_batch_target(%s) = %d, want %d\n", exe, got, want); }
    else printf("ok   is_batch_target(%s) = %d\n", exe, got);
}

int main(void) {
    const char *pre = "cmd.exe /e:ON /v:OFF /d /c \"";

    /* batch golden vectors (drang batch_test.go) */
    batch_ok("no args", "C:\\x.bat", 0, NULL, pre, "\"C:\\x.bat\"\"");
    { const char *a[] = {"hello"};            batch_ok("plain arg unquoted", "C:\\x.bat", 1, a, pre, "\"C:\\x.bat\" hello\""); }
    { const char *a[] = {"a b"};              batch_ok("space forces quote", "C:\\x.bat", 1, a, pre, "\"C:\\x.bat\" \"a b\"\""); }
    { const char *a[] = {"a\"b"};             batch_ok("embedded quote doubled", "C:\\x.bat", 1, a, pre, "\"C:\\x.bat\" \"a\"\"b\"\""); }
    { const char *a[] = {"a&b"};              batch_ok("ampersand quoted", "C:\\x.bat", 1, a, pre, "\"C:\\x.bat\" \"a&b\"\""); }
    { const char *a[] = {"%FOO%"};            batch_ok("percent neutralized", "C:\\x.bat", 1, a, pre, "\"C:\\x.bat\" \"%%cd:~,%FOO%%cd:~,%\"\""); }
    batch_ok("percent in script path", "C:\\a%b.bat", 0, NULL, pre, "\"C:\\a%%cd:~,%b.bat\"\"");
    batch_ok("var in script path", "C:\\%FOO%.bat", 0, NULL, pre, "\"C:\\%%cd:~,%FOO%%cd:~,%.bat\"\"");
    { const char *a[] = {""};                 batch_ok("empty arg quoted", "C:\\x.bat", 1, a, pre, "\"C:\\x.bat\" \"\"\""); }
    { const char *a[] = {"foo\\"};            batch_ok("trailing backslash doubled", "C:\\x.bat", 1, a, pre, "\"C:\\x.bat\" \"foo\\\\\"\""); }
    { const char *a[] = {"a\\b"};             batch_ok("lone backslash no quote", "C:\\x.bat", 1, a, pre, "\"C:\\x.bat\" a\\b\""); }
    { const char *a[] = {"a\" & echo INJECTED & echo"}; batch_ok("injection inert", "C:\\x.bat", 1, a, pre, "\"C:\\x.bat\" \"a\"\" & echo INJECTED & echo\"\""); }

    /* batch rejects */
    batch_reject("script with quote", "C:\\a\"b.bat", 0, NULL);
    batch_reject("script trailing backslash", "C:\\x\\", 0, NULL);
    batch_reject("script with CR", "C:\\x\r.bat", 0, NULL);
    { const char *a[] = {"a\rb"};             batch_reject("arg with CR", "C:\\x.bat", 1, a); }
    { const char *a[] = {"a\nb"};             batch_reject("arg with LF", "C:\\x.bat", 1, a); }

    /* EscapeArg (CommandLineToArgvW) */
    esc("plain", "hello", "hello");
    esc("space wraps", "a b", "\"a b\"");
    esc("embedded quote", "a\"b", "a\\\"b");
    esc("empty", "", "\"\"");
    esc("lone backslash", "a\\b", "a\\b");
    esc("trailing backslash with space", "a b\\", "\"a b\\\\\"");

    /* is_batch_target */
    bt("x.bat", 1); bt("x.cmd", 1); bt("C:\\dir\\Tool.BAT", 1); bt("C:\\dir\\run.Cmd", 1);
    bt("x.exe", 0); bt("x.com", 0); bt("x", 0); bt("x.bat.exe", 0); bt("C:\\dir\\tool.ps1", 0);

    printf("\n%d/%d passed, %d failed\n", total - fails, total, fails);
    return fails ? 1 : 0;
}
