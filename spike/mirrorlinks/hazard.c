/* hazard.c -- what does the destination hardlink check actually cost?
 *
 * `z mirror` refuses to write into a destination that contains a name-surrogate
 * reparse point or a file whose bytes are shared through hardlinks
 * (`validateMirrorDestinationHazards`, mirror_destination_windows.go). Per
 * entry it makes FOUR system calls:
 *
 *     GetFileAttributes(path)                     -- is it a directory?
 *     CreateFile(path, 0, ..., OPEN_REPARSE_POINT)
 *     GetFileInformationByHandle(h)               -- nNumberOfLinks
 *     CloseHandle(h)
 *
 * plus a DeviceIoControl for the few reparse points. This program takes the
 * same walk apart so the cost of each of those can be attributed, because the
 * question that decides whether mirror is portable is narrow: the reparse half
 * can be answered from the directory enumeration for free (see dirs.c), but
 * NO bulk directory info class carries a link count, so the hardlink half needs
 * a handle. How much is that handle worth?
 *
 * MODES
 *   walk   bulk enumeration only; reparse classified from the enumeration.
 *   files  + open/query/close per FILE.  Directories cannot be hardlinked on
 *          NTFS -- their link count is always 1 -- so opening them is waste,
 *          and this is the cheapest CORRECT shape.
 *   all    + open/query/close per ENTRY, files and directories alike.
 *   z      + a GetFileAttributesW first, which is z's shape exactly.
 *
 *   gcc -std=c23 -O2 -municode -o hazard.exe hazard.c
 *   hazard.exe <root> <walk|files|all|z> [runs]
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define BUFSZ (64 * 1024)
#define SURROGATE 0x20000000u

typedef enum { M_WALK, M_FILES, M_ALL, M_Z } Mode;

typedef struct {
    Mode          mode;
    long long     dirs, files, reparse, surrogates, multilink, errors;
    long long     opens;                   /* handles actually taken */
} Stats;

/* A growable UTF-16 path stack, so the walk is iterative and depth is bounded
 * by memory rather than by the C stack. */
typedef struct { wchar_t **v; size_t n, cap; } Stack;

static void push(Stack *s, wchar_t *p) {
    if (s->n == s->cap) {
        size_t nc = s->cap ? s->cap * 2 : 64;
        wchar_t **g = (wchar_t **)realloc(s->v, nc * sizeof *g);
        if (g == NULL) { free(p); return; }
        s->v = g; s->cap = nc;
    }
    s->v[s->n++] = p;
}

static wchar_t *joinw(const wchar_t *dir, const wchar_t *name, size_t nlen) {
    size_t dl = wcslen(dir);
    int sep = (dl && dir[dl - 1] != L'\\');
    wchar_t *out = (wchar_t *)malloc((dl + sep + nlen + 1) * sizeof(wchar_t));
    if (out == NULL) return NULL;
    memcpy(out, dir, dl * sizeof(wchar_t));
    if (sep) out[dl] = L'\\';
    memcpy(out + dl + sep, name, nlen * sizeof(wchar_t));
    out[dl + sep + nlen] = L'\0';
    return out;
}

/* The link count, the only fact that needs a handle. Opened with ZERO desired
 * access and FILE_FLAG_OPEN_REPARSE_POINT -- metadata only, and it does not
 * follow a reparse point, so a OneDrive placeholder is not recalled. This is
 * the same open z makes. */
/* The open is PARAMETERISED because the first head-to-head said Tcl's `file
 * stat` was twice as fast as this, which cannot be true of the same operation.
 * Varying the access mask and the reparse flag is how to find out which part of
 * the open the difference is in, rather than guessing. */
static DWORD g_access = 0;
static DWORD g_extra  = FILE_FLAG_OPEN_REPARSE_POINT;

static int linkcount(const wchar_t *path, int isdir, DWORD *links) {
    DWORD flags = g_extra;
    if (isdir) flags |= FILE_FLAG_BACKUP_SEMANTICS;
    HANDLE h = CreateFileW(path, g_access,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, flags, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    BY_HANDLE_FILE_INFORMATION bhfi;
    int ok = GetFileInformationByHandle(h, &bhfi) ? 1 : 0;
    if (ok) *links = bhfi.nNumberOfLinks;
    CloseHandle(h);
    return ok;
}

static void walk(const wchar_t *root, Stats *st) {
    Stack s = {0};
    wchar_t *r = (wchar_t *)malloc((wcslen(root) + 1) * sizeof(wchar_t));
    if (r == NULL) return;
    wcscpy(r, root);
    push(&s, r);

    char *buf = (char *)malloc(BUFSZ);
    if (buf == NULL) { free(r); free(s.v); return; }

    while (s.n) {
        wchar_t *dir = s.v[--s.n];
        st->dirs++;

        HANDLE h = CreateFileW(dir, FILE_LIST_DIRECTORY,
                               FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                               NULL, OPEN_EXISTING,
                               FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                               NULL);
        if (h == INVALID_HANDLE_VALUE) { st->errors++; free(dir); continue; }

        BOOL ok = GetFileInformationByHandleEx(h, FileIdBothDirectoryRestartInfo, buf, BUFSZ);
        while (ok) {
            size_t off = 0;
            for (;;) {
                FILE_ID_BOTH_DIR_INFO *e = (FILE_ID_BOTH_DIR_INFO *)(buf + off);
                size_t nlen = e->FileNameLength / sizeof(wchar_t);
                int dot = (nlen == 1 && e->FileName[0] == L'.')
                       || (nlen == 2 && e->FileName[0] == L'.' && e->FileName[1] == L'.');
                if (!dot) {
                    int isdir = (e->FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
                    DWORD tag = 0;
                    int reparse = (e->FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
                    if (reparse) {
                        /* The tag comes out of the enumeration -- no handle, no
                         * DeviceIoControl. This is the half that is free. */
                        tag = e->EaSize;
                        st->reparse++;
                        if (tag & SURROGATE) st->surrogates++;
                    }
                    if (!isdir) st->files++;

                    if (st->mode != M_WALK) {
                        int want = (st->mode == M_FILES) ? !isdir : 1;
                        if (want) {
                            wchar_t *p = joinw(dir, e->FileName, nlen);
                            if (p != NULL) {
                                if (st->mode == M_Z) {
                                    /* z asks the attributes again before opening,
                                     * although the enumeration just supplied them. */
                                    DWORD a = GetFileAttributesW(p);
                                    if (a == INVALID_FILE_ATTRIBUTES) st->errors++;
                                }
                                DWORD links = 1;
                                st->opens++;
                                if (linkcount(p, isdir, &links)) {
                                    if (!isdir && links > 1) st->multilink++;
                                } else {
                                    st->errors++;
                                }
                                free(p);
                            }
                        }
                    }
                    /* Descend, unless it is a name surrogate: a junction or a
                     * symlink redirects the namespace and the destination scan
                     * refuses it rather than entering it. */
                    if (isdir && !(reparse && (tag & SURROGATE))) {
                        wchar_t *p = joinw(dir, e->FileName, nlen);
                        if (p != NULL) push(&s, p);
                    }
                }
                if (e->NextEntryOffset == 0) break;
                off += e->NextEntryOffset;
                if (off >= BUFSZ) break;
            }
            ok = GetFileInformationByHandleEx(h, FileIdBothDirectoryInfo, buf, BUFSZ);
        }
        CloseHandle(h);
        free(dir);
    }
    free(buf);
    free(s.v);
}

static const wchar_t *prefixed(const wchar_t *in, wchar_t *out, size_t cap) {
    wchar_t full[32768];
    if (GetFullPathNameW(in, 32768, full, NULL) == 0) return in;
    if (full[0] == L'\\' && full[1] == L'\\') {
        swprintf(out, cap, L"\\\\?\\UNC\\%s", full + 2);
    } else {
        swprintf(out, cap, L"\\\\?\\%s", full);
    }
    return out;
}

/* THE HEAD-TO-HEAD. A tree walk carries too much variance to compare a single
 * per-file operation across languages -- three repeats of the same walk drifted
 * 3,501 / 5,159 / 6,520 ms. So the link-count probe is measured on its own, over
 * a FIXED list of paths read from a file, which is the same list the Tcl arm
 * reads. No enumeration, no directory order, nothing but the operation. */
static int mode_list(const wchar_t *listfile, int runs) {
    FILE *f = _wfopen(listfile, L"rb");
    if (f == NULL) { fwprintf(stderr, L"cannot open list\n"); return 1; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *raw = (char *)malloc((size_t)n + 1);
    if (raw == NULL) { fclose(f); return 1; }
    size_t got = fread(raw, 1, (size_t)n, f);
    raw[got] = '\0';
    fclose(f);

    /* One wide path per line. The list is written with the \\?\ prefix already
     * applied, so this program and the Tcl arm hand the OS the same string. */
    size_t cap = 4096, cnt = 0;
    wchar_t **paths = (wchar_t **)malloc(cap * sizeof *paths);
    char *line = strtok(raw, "\r\n");
    while (line != NULL) {
        if (*line) {
            int wl = MultiByteToWideChar(CP_UTF8, 0, line, -1, NULL, 0);
            wchar_t *w = (wchar_t *)malloc((size_t)wl * sizeof(wchar_t));
            if (w != NULL) {
                MultiByteToWideChar(CP_UTF8, 0, line, -1, w, wl);
                if (cnt == cap) {
                    cap *= 2;
                    paths = (wchar_t **)realloc(paths, cap * sizeof *paths);
                }
                paths[cnt++] = w;
            }
        }
        line = strtok(NULL, "\r\n");
    }
    free(raw);

    LARGE_INTEGER freq, a, b;
    QueryPerformanceFrequency(&freq);
    long long multi = 0, errs = 0;
    for (size_t i = 0; i < cnt; i++) { DWORD l = 1; linkcount(paths[i], 0, &l); }  /* warm */
    double best = 1e18;
    for (int r = 0; r < runs; r++) {
        multi = 0; errs = 0;
        QueryPerformanceCounter(&a);
        for (size_t i = 0; i < cnt; i++) {
            DWORD links = 1;
            if (linkcount(paths[i], 0, &links)) { if (links > 1) multi++; }
            else errs++;
        }
        QueryPerformanceCounter(&b);
        double ms = (double)(b.QuadPart - a.QuadPart) * 1000.0 / (double)freq.QuadPart;
        if (ms < best) best = ms;
    }
    wprintf(L"C  access=0x%08lx reparseflag=%d : %8.1f ms  %6.2f us/file  (%zu files, %lld multilink, %lld errors)\n",
            (unsigned long)g_access, g_extra ? 1 : 0,
            best, cnt ? best * 1000.0 / (double)cnt : 0.0, cnt, multi, errs);
    return 0;
}

int wmain(int argc, wchar_t **argv) {
    if (argc >= 3 && wcscmp(argv[2], L"list") == 0) {
        /* argv[4] optional: "none" | "readattr" | "read"; argv[5]: "noreparse" */
        if (argc > 4) {
            if      (wcscmp(argv[4], L"readattr") == 0) g_access = FILE_READ_ATTRIBUTES;
            else if (wcscmp(argv[4], L"read")     == 0) g_access = GENERIC_READ;
        }
        if (argc > 5 && wcscmp(argv[5], L"noreparse") == 0) g_extra = 0;
        return mode_list(argv[1], (argc > 3) ? _wtoi(argv[3]) : 3);
    }
    if (argc < 3) {
        fwprintf(stderr, L"usage: hazard <root> <walk|files|all|z> [runs]\n"
                         L"       hazard <listfile> list [runs]\n");
        return 2;
    }
    Mode mode;
    if      (wcscmp(argv[2], L"walk")  == 0) mode = M_WALK;
    else if (wcscmp(argv[2], L"files") == 0) mode = M_FILES;
    else if (wcscmp(argv[2], L"all")   == 0) mode = M_ALL;
    else if (wcscmp(argv[2], L"z")     == 0) mode = M_Z;
    else { fwprintf(stderr, L"unknown mode\n"); return 2; }
    int runs = (argc > 3) ? _wtoi(argv[3]) : 3;
    if (runs < 1) runs = 1;

    static wchar_t pbuf[32768];
    const wchar_t *root = prefixed(argv[1], pbuf, 32768);

    LARGE_INTEGER freq, a, b;
    QueryPerformanceFrequency(&freq);

    Stats warm = {0}; warm.mode = mode;
    walk(root, &warm);                       /* warm the cache, discard */

    double best = 1e18;
    Stats st = {0};
    for (int i = 0; i < runs; i++) {
        Stats cur = {0}; cur.mode = mode;
        QueryPerformanceCounter(&a);
        walk(root, &cur);
        QueryPerformanceCounter(&b);
        double ms = (double)(b.QuadPart - a.QuadPart) * 1000.0 / (double)freq.QuadPart;
        if (ms < best) { best = ms; st = cur; }
    }
    long long entries = st.dirs + st.files;
    wprintf(L"%-6s %9.0f ms  %6.2f us/entry  (%lld dirs, %lld files, %lld opens, "
            L"%lld reparse, %lld surrogate, %lld multilink, %lld errors)\n",
            argv[2], best, entries ? best * 1000.0 / (double)entries : 0.0,
            st.dirs, st.files, st.opens, st.reparse, st.surrogates,
            st.multilink, st.errors);
    return 0;
}
