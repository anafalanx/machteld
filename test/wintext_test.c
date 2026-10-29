/* Headless Win32 Unicode boundary and Windows argv round-trip properties.
 * Link with src/wintext.c src/winjob_cmdline.c and -lshell32. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include "wintext.h"
#include "winjob.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned total, failed;
static void check(const char *name, int ok) {
    total++;
    if (!ok) { failed++; printf("FAIL %s\n", name); }
}

static void roundtrip(const char *text) {
    wchar_t *wide = mt_utf8_to_wide(text);
    char *back = wide == NULL ? NULL : mt_wide_to_utf8(wide, -1);
    check("strict UTF-8/UTF-16 round-trip", back != NULL && strcmp(text, back) == 0);
    free(wide);
    free(back);
    const char *args[] = {"fixture.exe", text, "sentinel"};
    char *line = wj_make_cmdline(3, args);
    wchar_t *wline = line == NULL ? NULL : mt_utf8_to_wide(line);
    int argc = 0;
    wchar_t **argv = wline == NULL ? NULL : CommandLineToArgvW(wline, &argc);
    char *got = argv != NULL && argc == 3 ? mt_wide_to_utf8(argv[1], -1) : NULL;
    check("Windows argv round-trip", got != NULL && strcmp(got, text) == 0 &&
        wcscmp(argv[0], L"fixture.exe") == 0 && wcscmp(argv[2], L"sentinel") == 0);
    free(got);
    if (argv != NULL) LocalFree(argv);
    free(wline);
    free(line);
}

int main(void) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    static const char *invalid[] = {
        "\x80", "\xbf", "\xc0\x80", "\xc1\xbf", "\xc2", "\xe0\x80\x80",
        "\xed\xa0\x80", "\xed\xbf\xbf", "\xf0\x80\x80\x80",
        "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xff", NULL
    };
    for (size_t i = 0; invalid[i] != NULL; i++) {
        wchar_t *wide = mt_utf8_to_wide(invalid[i]);
        check("malformed UTF-8 rejected", wide == NULL);
        free(wide);
    }
    static const wchar_t invalid_wide[][4] = {
        {0xd800, 0}, {0xdc00, 0}, {'a', 0xd800, 'b', 0}, {0xdc00, 0xd800, 0}
    };
    for (size_t i = 0; i < sizeof invalid_wide / sizeof *invalid_wide; i++) {
        char *text = mt_wide_to_utf8(invalid_wide[i], -1);
        check("unpaired UTF-16 surrogate rejected", text == NULL);
        free(text);
    }
    check("NULL UTF-8 rejected", mt_utf8_to_wide(NULL) == NULL);
    check("NULL UTF-16 rejected", mt_wide_to_utf8(NULL, -1) == NULL);
    check("zero UTF-16 count rejected", mt_wide_to_utf8(L"test", 0) == NULL);
    const wchar_t counted[] = {'a', 0, 'b'};
    char *text = mt_wide_to_utf8(counted, 3);
    check("counted UTF-16 preserves embedded NUL", text != NULL && memcmp(text, "a\0b\0", 4) == 0);
    free(text);
    check("NULL normal argv rejected", wj_make_cmdline(1, NULL) == NULL);
    const char *bad_args[] = {NULL};
    check("NULL normal argv element rejected", wj_make_cmdline(1, bad_args) == NULL);
    check("negative normal argc rejected", wj_make_cmdline(-1, NULL) == NULL);
    text = wj_make_cmdline(0, NULL);
    check("empty command line is empty", text != NULL && *text == '\0');
    free(text);

    static const char *pieces[] = {
        "a", "0", " ", "\t", "\r", "\n", "\"", "\\", "\\\"", "\\\\",
        "&", "%", "!", "|", "\xc3\xa9", "\xe4\xb8\x96", "\xf0\x9f\x98\x80", "\xf4\x8f\xbf\xbf"
    };
    uint32_t seed = 0x5a17;
    roundtrip("");
    for (unsigned test = 0; test < 256; test++) {
        char buffer[1024] = "";
        for (unsigned part = 0; part < 32; part++) {
            seed = seed * UINT32_C(1664525) + UINT32_C(1013904223);
            strcat(buffer, pieces[seed % (sizeof pieces / sizeof *pieces)]);
        }
        roundtrip(buffer);
    }
    char *large = malloc(32001);
    if (large == NULL) return 2;
    memset(large, '\\', 31998);
    large[0] = ' ';
    large[31998] = '"';
    large[31999] = '\\';
    large[32000] = '\0';
    roundtrip(large);
    free(large);
    printf("native text: %u/%u passed; %u failed; seed 0x5a17\n", total - failed, total, failed);
    return failed ? 1 : 0;
}
