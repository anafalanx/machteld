/*
 * dirs.c -- directory walking, reparse-point inspection, and canonical identity.
 *
 * Native enumeration is used because Tcl's glob filters do not express "all
 * directories, including entries with the Windows hidden attribute" directly.
 * A walk never presents a silent partial result: every omitted branch is
 * accounted for by `errors`, `pruned`, `depthlimited`, or a `links` row.
 *
 * Name-surrogate reparse points (junctions, symlinks, mount points, DFS) are
 * reported and not entered. Other reparse tags, such as cloud placeholders,
 * remain ordinary content. Classification is rechecked on a handle immediately
 * before descent so replacing a scanned directory with a junction cannot escape
 * the requested tree. The handle may veto descent but never overrides a
 * surrogate classification already observed in the directory scan.
 */
#undef USE_TCL_STUBS
#include "machteld.h"

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
/* FSCTL_GET_REPARSE_POINT and MAXIMUM_REPARSE_DATA_BUFFER_SIZE live here rather
 * than in windows.h -- `links` reads a reparse payload, `dirs` never did. */
#include <winioctl.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <wchar.h>

/* A reparse tag with this bit set is A NAME FOR SOMETHING ELSE (junction,
 * symlink, volume mount point). Everything else is content behind a filter. */
#define DIRS_SURROGATE 0x20000000u

/* DFS and DFSR are namespace redirections but do not set the surrogate bit. */
#define DIRS_TAG_DFS  0x8000000Au
#define DIRS_TAG_DFSR 0x80000012u

/* The bit is a FACT and is reported as `surrogate`; this is the DECISION, and
 * they are separate keys in the row so a reader can see the two disagree. */
static int dirs_isname(DWORD tag) {
    return (tag & DIRS_SURROGATE) != 0 || tag == DIRS_TAG_DFS || tag == DIRS_TAG_DFSR;
}

/* The enumeration buffer. 64 KB is a THROUGHPUT choice, not a correctness
 * bound, and it is worth saying so because the specification justified it as
 * one: "a 32,767-char name needs 64 KB" confuses the maximum PATH length with
 * the maximum COMPONENT length. A component is at most 255 UTF-16 units, so the
 * largest single FILE_ID_BOTH_DIR_INFO entry is about 622 bytes and the growth
 * path below can only ever fire on a filesystem that disagrees. It is still
 * written, and it grows on BOTH failure codes -- measured, a 64-byte buffer
 * returns ERROR_NOT_ENOUGH_MEMORY (24), never the ERROR_MORE_DATA (234) the
 * documentation leads you to expect, and a walker that grows only on 234 files
 * an ordinary error row and silently truncates the directory. */
#define DIRS_BUFSZ 65536

static int dirs_error(Tcl_Interp *interp, const char *code, const char *msg) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "DIRS", code, (char *)NULL);
    return TCL_ERROR;
}

/* One directory waiting to be listed. `reparse`/`tag`/`surrogate` are what the
 * PARENT's scan said; the walk re-asks the kernel before it descends. */
typedef struct {
    wchar_t *path;      /* \\?\-prefixed and owned by the stack */
    int      depth;
    int      reparse;
    DWORD    tag;
    int      surrogate; /* the 0x20000000 bit, reported as-is */
    int      noenter;   /* the decision: surrogate OR a DFS redirection */
    int      pruned;
} DirsItem;

/* One child of the directory being enumerated, kept until the batch is sorted.
 * The name is carried twice on purpose: the UTF-16 form builds the child path,
 * and the UTF-8 form is what gets sorted and what `-prune` is matched against,
 * because Tcl's own matcher takes UTF-8. */
typedef struct {
    char    *name;
    wchar_t *wname;
    size_t   wlen;
    DWORD    tag;
    int      reparse;
    int      surrogate;
    int      noenter;
    int      pruned;
} DirsChild;

/* WHAT THE WALK IS BEING ASKED FOR. `dirs` lists directories; `links` reports
 * the reparse points and (on request) the multiply-linked files it passes. One
 * walker serves both, because two walkers is two answers to "what is under
 * here" and this file exists to have one. In DIRS mode every branch below
 * behaves exactly as it did before the mode existed -- the 809 checks are the
 * gate on that, and they run unchanged. */
#define DIRS_MODE_DIRS  0
#define DIRS_MODE_LINKS 1

typedef struct {
    Tcl_Obj     *paths;
    Tcl_Obj     *links;
    Tcl_Obj     *errors;
    Tcl_WideInt  count;
    Tcl_WideInt  pruned;
    Tcl_WideInt  depthlimited;
    Tcl_WideInt  maxdepth;
    int          depthcap;   /* -1 is unlimited, and unlimited is spelled by omission */
    int          unc;        /* the root is \\?\UNC\..., so the prefix strips differently */
    /* THE PATTERNS ARE OWNED, NOT BORROWED, and that is a bug fix rather than a
     * style. `prunev` used to be the raw element array of the CALLER's `-prune`
     * object, held for the whole walk. Hand the same Tcl_Obj to `-depth` as
     * well -- `dirs $d -prune $v -depth $v` -- and `Tcl_GetWideIntFromObj`
     * shimmers it to a number, freeing the list rep and its ListStore, while
     * `prunec` still says there is one pattern. Measured: the read did not
     * crash, it silently matched nothing, so the subtree the caller asked to
     * exclude was walked and listed and `pruned` reported 0. No error, no row --
     * this file's whole thesis inverted, since its guarantee is about what goes
     * MISSING and says nothing about what should have been left out. */
    Tcl_Obj     *pruneobj;   /* our own copy, ref held for the walk's lifetime */
    Tcl_Size     prunec;
    Tcl_Obj    **prunev;     /* into pruneobj, which nothing else can shimmer */

    /* --- links mode only ------------------------------------------------- */
    int          mode;
    int          hardlinks;  /* -hardlinks: also report files with nlinks > 1 */
    Tcl_Obj     *entries;    /* {path .. type .. target ..} per name surrogate */
    Tcl_Obj     *multi;      /* {path .. links N} per multiply-linked file */
    Tcl_Obj     *entered;    /* non-surrogate reparse dirs successfully enumerated */
    Tcl_WideInt  files;
    Tcl_WideInt  multilink;
} DirsWalk;

/* MB_ERR_INVALID_CHARS IS THE MIRROR OF THE FLAG BELOW, and the two have to
 * match or the guard is one-directional. Without it MultiByteToWideChar
 * substitutes U+FFFD and reports SUCCESS, so a root Tcl is holding with an
 * unpaired surrogate would be silently rewritten and this verb would walk a
 * DIFFERENT directory -- or answer `notfound` blaming the caller's spelling for
 * a name the caller never wrote. The out-bound rule is that a name we cannot
 * represent is refused rather than renamed; the in-bound rule is the same one. */
static wchar_t *u8_to_u16(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (w == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w, n) <= 0) { free(w); return NULL; }
    return w;
}

/* UTF-16 -> UTF-8, length-taking because the names in FILE_ID_BOTH_DIR_INFO are
 * NOT NUL-terminated -- FileNameLength is the only thing that says where they
 * stop, including for the `.` and `..` test.
 *
 * WC_ERR_INVALID_CHARS IS DELIBERATE AND IT IS THE POINT. NTFS accepts names
 * containing unpaired surrogates (the NT API will create them even though Win32
 * will not), and without this flag WideCharToMultiByte substitutes U+FFFD and
 * reports SUCCESS -- measured, {a, D800, b} comes back as 61 ef bf bd 62 with no
 * error. That produces a `paths` entry that cannot be reopened, and two such
 * siblings collapse into one string: a duplicate that looks like a walker bug.
 * A verb whose thesis is that silence is arithmetically impossible cannot
 * silently rename a directory, so the conversion fails and the caller turns the
 * failure into a counted `errors` row. */
static char *u16_to_u8n(const wchar_t *w, int n) {
    int need = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, w, n, NULL, 0, NULL, NULL);
    if (need <= 0) return NULL;
    char *s = (char *)malloc((size_t)need + 1);
    if (s == NULL) return NULL;
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, w, n, s, need, NULL, NULL) <= 0) {
        free(s);
        return NULL;
    }
    s[need] = '\0';
    return s;
}

/* FormatMessage's text, trimmed. It ends in CR LF and would otherwise carry the
 * line break into every row of the result dict and into anything comparing it.
 * The wording is the system's, in the system's language -- said here so nobody
 * writes a test that matches on it; `win32` is the field to trap on. */
static char *dirs_reason(DWORD e) {
    wchar_t *wmsg = NULL;
    DWORD n = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM
                             | FORMAT_MESSAGE_IGNORE_INSERTS,
                             NULL, e, 0, (wchar_t *)&wmsg, 0, NULL);
    if (n == 0 || wmsg == NULL) return NULL;
    while (n > 0 && (wmsg[n - 1] == L'\r' || wmsg[n - 1] == L'\n' || wmsg[n - 1] == L' ')) n--;
    char *s = u16_to_u8n(wmsg, (int)n);
    LocalFree(wmsg);
    return s;
}

/* Parent + separator + name, as a fresh \\?\-prefixed path.
 *
 * THE SEPARATOR IS ADDED ONLY WHEN THE PARENT LACKS ONE, and that is not
 * fussiness. Under \\?\ the object manager does no normalisation whatsoever, so
 * a doubled separator is a real empty path component: measured,
 * \\?\C:\dev\_machteld\\build fails with ERROR_INVALID_NAME (123) and the UNC
 * form fails with ERROR_BAD_PATHNAME (161). The one place it survives is
 * immediately after a drive letter, which is exactly the case that made this
 * look harmless in testing. */
static wchar_t *dirs_join(const wchar_t *parent, size_t plen, const wchar_t *name, size_t nlen) {
    int sep = (plen > 0 && parent[plen - 1] != L'\\') ? 1 : 0;
    wchar_t *p = (wchar_t *)malloc((plen + (size_t)sep + nlen + 1) * sizeof(wchar_t));
    if (p == NULL) return NULL;
    memcpy(p, parent, plen * sizeof(wchar_t));
    if (sep) p[plen] = L'\\';
    memcpy(p + plen + sep, name, nlen * sizeof(wchar_t));
    p[plen + sep + nlen] = L'\0';
    return p;
}

/* The \\?\ prefix comes off on the way out, and backslashes become forward
 * slashes. A UNC root needs its own case:
 * \\?\UNC\server\share is EIGHT characters of prefix standing in for two, and
 * stripping the usual four yields UNC/server/share, a path that does not
 * exist. */
static char *dirs_strip(const wchar_t *w, int unc) {
    size_t skip = unc ? 8 : 4;
    char *tail = u16_to_u8n(w + skip, -1);
    char *out = tail;
    if (tail == NULL) return NULL;
    if (unc) {
        size_t n = strlen(tail);
        out = (char *)malloc(n + 3);
        if (out == NULL) { free(tail); return NULL; }
        out[0] = '/';
        out[1] = '/';
        memcpy(out + 2, tail, n + 1);
        free(tail);
    }
    for (char *c = out; *c; c++) {
        if (*c == '\\') *c = '/';
    }
    return out;
}

/* Sibling order is part of the contract, so it is fixed here rather than left
 * to the filesystem. NTFS hands entries back in its index B-tree order, which is
 * a case-insensitive upcase collation: measured, five directories enumerate as
 * `aa AB b1 Zz _z` and sort as `AB Zz _z aa b1` -- completely disjoint. A walker
 * that pushes children in enumeration order is not wrong about the SET, so
 * nothing catches it except a byte-for-byte diff of two cache files written on
 * two machines.
 *
 * The comparison is on the UTF-8 encoding, whose byte order IS code-point order,
 * and it is unsigned. Two traps live here: `strcmp` with a signed char type puts
 * every non-ASCII name BEFORE `a`, and sorting the UTF-16 form instead puts a
 * supplementary-plane name before U+E000 because its lead surrogate is 0xD83D.
 * Both produce a plausible order that is not this one. */
static int dirs_namecmp(const void *a, const void *b) {
    const DirsChild *x = (const DirsChild *)a;
    const DirsChild *y = (const DirsChild *)b;
    size_t xn = strlen(x->name), yn = strlen(y->name);
    size_t m = xn < yn ? xn : yn;
    int c = memcmp(x->name, y->name, m);
    if (c != 0) return c;
    return xn < yn ? -1 : (xn > yn ? 1 : 0);
}

/* FILE_LIST_DIRECTORY plus BACKUP_SEMANTICS is the only way to get a handle to a
 * directory at all. `follow` decides whether a reparse point is entered or
 * merely opened: without FILE_FLAG_OPEN_REPARSE_POINT a junction handle reports
 * the TARGET's attributes and enumerates the target's contents, which is
 * precisely the escape this verb must not make. */
static HANDLE dirs_open(const wchar_t *path, int follow) {
    DWORD flags = FILE_FLAG_BACKUP_SEMANTICS;
    if (!follow) flags |= FILE_FLAG_OPEN_REPARSE_POINT;
    return CreateFileW(path, FILE_LIST_DIRECTORY,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       NULL, OPEN_EXISTING, flags, NULL);
}

static Tcl_Obj *dirs_link_row(const char *path, DWORD tag, int surrogate, const char *action) {
    Tcl_Obj *d = Tcl_NewDictObj();
    char hex[16];
    snprintf(hex, sizeof hex, "0x%08lx", (unsigned long)tag);
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("path", -1), Tcl_NewStringObj(path ? path : "", -1));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("tag", -1), Tcl_NewStringObj(hex, -1));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("surrogate", -1), Tcl_NewIntObj(surrogate));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("action", -1), Tcl_NewStringObj(action, -1));
    return d;
}

/* The raw Win32 code travels with the message because the message cannot be
 * trapped on and, at this layer, does not discriminate: a directory pending
 * delete and an ACL denial both arrive as ERROR_ACCESS_DENIED. */
static Tcl_Obj *dirs_err_row(const char *path, DWORD e, const char *reason) {
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("path", -1), Tcl_NewStringObj(path ? path : "", -1));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("win32", -1), Tcl_NewWideIntObj((Tcl_WideInt)e));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("reason", -1), Tcl_NewStringObj(reason ? reason : "", -1));
    return d;
}

static void dirs_fault(DirsWalk *w, const wchar_t *path, DWORD e) {
    char *p = dirs_strip(path, w->unc);
    char *why = dirs_reason(e);
    Tcl_ListObjAppendElement(NULL, w->errors, dirs_err_row(p ? p : "", e, why ? why : ""));
    free(p);
    free(why);
}

/* Read one directory into a freshly allocated, sorted child array.
 *
 * THE RESTART CALL RETURNS THE FIRST BATCH -- it is not a seek. Written as the
 * specification had it,
 *
 *     GetFileInformationByHandleEx(h, FileIdBothDirectoryRestartInfo, buf, n);
 *     while (GetFileInformationByHandleEx(h, FileIdBothDirectoryInfo, buf, n)) { ... }
 *
 * the loop condition overwrites `buf` with the SECOND batch before the body ever
 * sees the first, and at 64 KB almost every directory fits in one batch -- so the
 * body runs zero times, `paths` comes back holding the root alone, `errors` is
 * empty, and the verb reports a clean, plausible, entirely empty answer. Hence
 * the do/while shape: process what you were given, then ask for more. */
/* --- links mode: naming a reparse point, and reading where it points -------- */
static const char *links_type(DWORD tag, int isdir) {
    if (tag == IO_REPARSE_TAG_SYMLINK) {
        return isdir ? "directory symlink" : "file symlink";
    }
    if (tag == 0xa0000003u) return "junction";   /* IO_REPARSE_TAG_MOUNT_POINT */
    return NULL;                                  /* a surrogate we cannot name */
}

/* mingw's headers do not declare the reparse payload, so it is declared here.
 * Both link shapes put the same four offsets first; only the symlink adds
 * `Flags`, which is why the two cases cannot share one struct. */
typedef struct {
    DWORD ReparseTag;
    WORD  ReparseDataLength;
    WORD  Reserved;
    union {
        struct {
            WORD  SubstituteNameOffset;
            WORD  SubstituteNameLength;
            WORD  PrintNameOffset;
            WORD  PrintNameLength;
            ULONG Flags;
            WCHAR PathBuffer[1];
        } Symlink;
        struct {
            WORD  SubstituteNameOffset;
            WORD  SubstituteNameLength;
            WORD  PrintNameOffset;
            WORD  PrintNameLength;
            WCHAR PathBuffer[1];
        } Mount;
        struct { UCHAR DataBuffer[1]; } Generic;
    } u;
} LinksReparse;

#define LINKS_SYMLINK_RELATIVE 0x00000001u

/* Return the substitute name rather than the optional (and possibly empty)
 * print name, with the object-manager prefix `\??\`
 * stripped and `\??\UNC\` folded back to `\\` -- and a RELATIVE symlink left
 * exactly as written, since there is nothing to strip and prefixing one would
 * invent a target. Returns malloc'd UTF-8, or NULL. */
static char *links_target(const wchar_t *path, int isdir) {
    DWORD flags = FILE_FLAG_OPEN_REPARSE_POINT;
    if (isdir) flags |= FILE_FLAG_BACKUP_SEMANTICS;
    HANDLE h = CreateFileW(path, 0,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, flags, NULL);
    if (h == INVALID_HANDLE_VALUE) return NULL;

    char *raw = (char *)malloc(MAXIMUM_REPARSE_DATA_BUFFER_SIZE);
    if (raw == NULL) { CloseHandle(h); return NULL; }
    DWORD got = 0;
    if (!DeviceIoControl(h, FSCTL_GET_REPARSE_POINT, NULL, 0,
                         raw, MAXIMUM_REPARSE_DATA_BUFFER_SIZE, &got, NULL)
        || got < sizeof(DWORD)) {          /* enough for ReparseTag, and no more */
        free(raw);
        CloseHandle(h);
        return NULL;
    }
    CloseHandle(h);

    LinksReparse *r = (LinksReparse *)raw;
    const WCHAR *base;
    WORD off, len;
    size_t hdr;                            /* bytes before PathBuffer, per ARM */
    int relative = 0;
    /* THE FIXED PART MUST BE PRESENT BEFORE ITS FIELDS ARE READ. A `got < 8`
     * guard covers the tag and nothing else: the symlink arm then reads four
     * WORDs AND a ULONG Flags -- twenty bytes in -- and `off`/`len` feed the
     * bounds check below, so with a short payload the guard decides safety from
     * uninitialised heap, and `relative` picks between two different answers
     * from the same garbage. Checked per arm, before the first read. */
    if (r->ReparseTag == IO_REPARSE_TAG_SYMLINK) {
        hdr = offsetof(LinksReparse, u.Symlink.PathBuffer);
        if ((size_t)got < hdr) { free(raw); return NULL; }
        base = r->u.Symlink.PathBuffer;
        off  = r->u.Symlink.SubstituteNameOffset;
        len  = r->u.Symlink.SubstituteNameLength;
        relative = (r->u.Symlink.Flags & LINKS_SYMLINK_RELATIVE) != 0;
    } else if (r->ReparseTag == 0xa0000003u) {
        hdr = offsetof(LinksReparse, u.Mount.PathBuffer);
        if ((size_t)got < hdr) { free(raw); return NULL; }
        base = r->u.Mount.PathBuffer;
        off  = r->u.Mount.SubstituteNameOffset;
        len  = r->u.Mount.SubstituteNameLength;
    } else {
        free(raw);
        return NULL;
    }
    /* `off` IS RELATIVE TO PathBuffer, NOT TO THE STRUCT, and the first version
     * of this line added `offsetof(LinksReparse, u)` -- the offset of the UNION.
     * Measured with the pinned toolchain: the union is at 8, but PathBuffer is
     * at 20 in the symlink arm and 16 in the mount arm, so the check under-
     * counted by 12 and 8. One constant cannot be right for both, which is the
     * same reason the two arms cannot share a struct. A payload with
     * `off = 0, len = 16376, got = 16384` passed and read 12 bytes past a
     * 16 KB malloc -- demonstrated, with a guard page, as a segfault.
     *
     * Local NTFS leaves slack, but network and user-space filesystems can return
     * malformed payloads, so the bounds check remains mandatory. */
    if (hdr + (size_t)off + (size_t)len > (size_t)got) {
        free(raw);
        return NULL;
    }
    const WCHAR *name = (const WCHAR *)((const char *)base + off);
    size_t n = len / sizeof(WCHAR);

    if (!relative) {
        if (n >= 4 && name[0] == L'\\' && name[1] == L'?' && name[2] == L'?' && name[3] == L'\\') {
            name += 4;
            n    -= 4;
            if (n >= 4 && (name[0] == L'U' || name[0] == L'u')
                       && (name[1] == L'N' || name[1] == L'n')
                       && (name[2] == L'C' || name[2] == L'c') && name[3] == L'\\') {
                /* \??\UNC\server\share -> \\server\share */
                char *tail = u16_to_u8n(name + 3, (int)(n - 3));
                if (tail == NULL) { free(raw); return NULL; }
                size_t tl = strlen(tail);
                char *out = (char *)malloc(tl + 2);
                if (out == NULL) { free(tail); free(raw); return NULL; }
                out[0] = '\\';
                memcpy(out + 1, tail, tl + 1);
                free(tail);
                free(raw);
                return out;
            }
        }
    }
    char *out = u16_to_u8n(name, (int)n);
    free(raw);
    return out;
}

/* Link counts need one handle per file. NTFS does not permit hard links to
 * directories, so directory handles cannot contribute useful information. */
/* Returns 0 ONLY when the answer could not be obtained, and leaves GetLastError
 * set for the caller's error row. NTFS never reports zero links for a file that
 * exists, so 0 is unambiguous as a failure signal. */
static DWORD links_nlinks(const wchar_t *path) {
    HANDLE h = CreateFileW(path, 0,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    BY_HANDLE_FILE_INFORMATION bhfi;
    DWORD err = 0, n = 0;
    if (GetFileInformationByHandle(h, &bhfi)) {
        n = bhfi.nNumberOfLinks;
    } else {
        err = GetLastError();
    }
    CloseHandle(h);          /* CloseHandle clobbers GetLastError; restore it */
    if (n == 0) SetLastError(err ? err : ERROR_ACCESS_DENIED);
    return n;
}

/* One row per surrogate. `tag` travels with it for the same reason it does in
 * `dirs`: an unnameable surrogate is still a fact, and a caller that cannot
 * classify it can still be told the number. */
static void links_record(DirsWalk *w, const wchar_t *full, const char *shown,
                         DWORD tag, int isdir) {
    const char *type = links_type(tag, isdir);
    char *target = links_target(full, isdir);
    char hex[16];
    snprintf(hex, sizeof hex, "0x%08lx", (unsigned long)tag);
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("path", -1),
                   Tcl_NewStringObj(shown ? shown : "", -1));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("type", -1),
                   Tcl_NewStringObj(type ? type : "", -1));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("target", -1),
                   Tcl_NewStringObj(target ? target : "", -1));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("tag", -1), Tcl_NewStringObj(hex, -1));
    Tcl_ListObjAppendElement(NULL, w->entries, d);
    free(target);
    /* An unclassified surrogate or unreadable target is an error row; returning
     * an apparently complete link inventory would be unsafe. */
    if (type == NULL) {
        dirs_fault(w, full, ERROR_NOT_SUPPORTED);
    } else if (target == NULL) {
        dirs_fault(w, full, ERROR_INVALID_DATA);
    }
}

static int dirs_children(DirsWalk *w, HANDLE h, DirsItem *it,
                         DirsChild **out, size_t *outn) {
    size_t bufsz = DIRS_BUFSZ;
    /* malloc, not a stack array: these info classes require LONGLONG alignment
     * and gcc/ucrt64 -- the pinned compiler -- IGNORES __declspec(align(8)) with
     * a warning nobody reads. malloc is aligned for every scalar type by
     * definition, and the buffer has to be growable anyway. */
    char *buf = (char *)malloc(bufsz);
    /* A ROW, NOT A BARE `return 0`. Without it the whole subtree vanishes with
     * no counted cause and the walk still answers TCL_OK -- a clean, plausible,
     * short list, which is the one outcome the header at the top of this file
     * says must be impossible. Every allocation failure below is counted the
     * same way, and `dirs_fault` allocating too is best-effort by nature: it can
     * only ever produce a row with an empty `path`, never no row at all. */
    if (buf == NULL) { dirs_fault(w, it->path, ERROR_NOT_ENOUGH_MEMORY); return 0; }

    BOOL ok = GetFileInformationByHandleEx(h, FileIdBothDirectoryRestartInfo, buf, (DWORD)bufsz);
    while (!ok && (GetLastError() == ERROR_MORE_DATA || GetLastError() == ERROR_NOT_ENOUGH_MEMORY)
           && bufsz < (size_t)16 * 1024 * 1024) {
        char *bigger = (char *)realloc(buf, bufsz * 2);
        if (bigger == NULL) break;
        buf = bigger;
        bufsz *= 2;
        ok = GetFileInformationByHandleEx(h, FileIdBothDirectoryRestartInfo, buf, (DWORD)bufsz);
    }
    if (!ok) {
        DWORD e = GetLastError();
        free(buf);
        /* ERROR_NO_MORE_FILES on the FIRST call is an empty directory, which is
         * not a failure. Everything else is, including ERROR_INVALID_PARAMETER
         * (87) -- what a FILE opened with BACKUP_SEMANTICS answers when it is
         * asked to enumerate, and what a redirector that does not implement this
         * info class answers too. */
        if (e == ERROR_NO_MORE_FILES) { *out = NULL; *outn = 0; return 1; }
        dirs_fault(w, it->path, e);
        return 0;
    }

    DirsChild *kids = NULL;
    size_t n = 0, cap = 0;
    /* COUNTS, NOT FLAGS. Both of these used to be one `int` per directory, so N
     * lost children produced exactly ONE row and the arithmetic the header
     * promises could be satisfied as an EXISTENCE claim while the cardinality a
     * caller needs to actually close it was gone. One row per lost directory. */
    size_t bad_name = 0;
    size_t lost = 0;
    size_t overrun = 0;

    do {
        size_t off = 0;
        for (;;) {
            /* THE ONLY UNCHECKED POINTER ADVANCE IN THIS FILE, until now. The
             * kernel is the source and the chain is the documented idiom, so
             * this is not defending against a plausible bug -- it is refusing to
             * have one place where a wrong answer becomes a wild read. A chain
             * that leaves the buffer is a counted row like everything else. */
            if (off + offsetof(FILE_ID_BOTH_DIR_INFO, FileName) > bufsz) { overrun = 1; break; }
            FILE_ID_BOTH_DIR_INFO *e = (FILE_ID_BOTH_DIR_INFO *)(buf + off);
            if ((e->FileNameLength % sizeof(wchar_t)) != 0) { overrun = 1; break; }
            size_t nlen = e->FileNameLength / sizeof(wchar_t);
            if (off + offsetof(FILE_ID_BOTH_DIR_INFO, FileName) + e->FileNameLength > bufsz) {
                overrun = 1;
                break;
            }
            int skip = 0;
            if (nlen == 1 && e->FileName[0] == L'.') skip = 1;
            if (nlen == 2 && e->FileName[0] == L'.' && e->FileName[1] == L'.') skip = 1;
            /* Files are never listed by `dirs`. In links mode the enumeration
             * already carries file attributes and reparse tags; only the link
             * count requires an extra handle, so `-hardlinks` stays opt-in.
             *
             * A file is never pushed on the stack in either mode -- there is
             * nothing under it to walk -- so it is dealt with here, entirely,
             * and then skipped. */
            if (!(e->FileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
                if (w->mode == DIRS_MODE_LINKS) {
                    w->files++;
                    int fileparse = (e->FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
                    DWORD ftag = fileparse ? e->EaSize : 0;
                    /* `skip` is still 1 here only for `.` and `..`, which are
                     * directories and cannot reach this branch -- tested rather
                     * than assumed, because the guard is free and a `.` entry
                     * joined onto its parent is a path that names the parent. */
                    int wants = (fileparse && dirs_isname(ftag)) || w->hardlinks;
                    if (wants && !skip) {
                        wchar_t *fp = dirs_join(it->path, wcslen(it->path), e->FileName, nlen);
                        if (fp == NULL) {
                            dirs_fault(w, it->path, ERROR_NOT_ENOUGH_MEMORY);
                        } else {
                            char *fshown = dirs_strip(fp, w->unc);
                            if (fileparse && dirs_isname(ftag)) {
                                links_record(w, fp, fshown, ftag, 0);
                            }
                            /* A reparse point is not a candidate for the
                             * hardlink question: its bytes are a link payload,
                             * not shared content, and opening one to ask would
                             * be a second handle for an answer that cannot
                             * matter. */
                            if (w->hardlinks && !fileparse) {
                                DWORD nl = links_nlinks(fp);
                                /* A FILE WE COULD NOT OPEN IS NOT A FILE WITH
                                 * ONE LINK. `links_nlinks` returns 0 for a
                                 * failed open, a failed query and (nominally) a
                                 * real zero alike, and `nl > 1` folded all three
                                 * into "nothing to report" with no row -- so
                                 * `links C:/ -hardlinks` answered `multilinked 0,
                                 * errors 0` over a root where three of five files
                                 * (pagefile.sys, swapfile.sys, the SAM hive) cannot
                                 * be opened at all. Under WinSxS, where servicing
                                 * hardlinks live in bulk beside locked and
                                 * ACL-denied files, that silence is the answer
                                 * being wrong about the very thing it was asked.
                                 * The contract this file states for a surrogate
                                 * whose target cannot be read now holds for the
                                 * link count too. */
                                if (nl == 0) {
                                    dirs_fault(w, fp, GetLastError());
                                } else if (nl > 1) {
                                    w->multilink++;
                                    Tcl_Obj *m = Tcl_NewDictObj();
                                    Tcl_DictObjPut(NULL, m, Tcl_NewStringObj("path", -1),
                                                   Tcl_NewStringObj(fshown ? fshown : "", -1));
                                    Tcl_DictObjPut(NULL, m, Tcl_NewStringObj("links", -1),
                                                   Tcl_NewWideIntObj((Tcl_WideInt)nl));
                                    Tcl_ListObjAppendElement(NULL, w->multi, m);
                                }
                            }
                            free(fshown);
                            free(fp);
                        }
                    }
                }
                skip = 1;
            }
            if (!skip) {
                if (n == cap) {
                    size_t ncap = cap ? cap * 2 : 32;
                    DirsChild *g = (DirsChild *)realloc(kids, ncap * sizeof(DirsChild));
                    if (g == NULL) { skip = 1; lost++; }
                    else { kids = g; cap = ncap; }
                }
            }
            if (!skip) {
                DirsChild *k = &kids[n];
                k->name = u16_to_u8n(e->FileName, (int)nlen);
                k->wname = NULL;
                k->wlen = nlen;
                k->tag = 0;
                k->reparse = 0;
                k->surrogate = 0;
                k->noenter = 0;
                k->pruned = 0;
                if (k->name == NULL) {
                    /* The name is not representable -- see u16_to_u8n. Counted,
                     * against the parent, because the child has no name we could
                     * put in the row. */
                    bad_name++;
                } else {
                    k->wname = (wchar_t *)malloc((nlen + 1) * sizeof(wchar_t));
                    if (k->wname == NULL) { free(k->name); lost++; }
                    else {
                        memcpy(k->wname, e->FileName, nlen * sizeof(wchar_t));
                        k->wname[nlen] = L'\0';
                        /* THE TAG IS ONLY MEANINGFUL WHEN THE REPARSE BIT IS SET.
                         * EaSize is a genuine extended-attribute size otherwise:
                         * measured, FindFirstFileW on an ordinary directory
                         * returned attrs=00000010 with a0000003 still sitting in
                         * the tag field, left over from a previous entry. Reading
                         * it ungated turns a plain directory into a junction. */
                        if (e->FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
                            k->reparse = 1;
                            k->tag = e->EaSize;
                            k->surrogate = (k->tag & DIRS_SURROGATE) != 0;
                            k->noenter = dirs_isname(k->tag);
                        }
                        for (Tcl_Size i = 0; i < w->prunec; i++) {
                            if (Tcl_StringCaseMatch(k->name, Tcl_GetString(w->prunev[i]),
                                                    TCL_MATCH_NOCASE)) {
                                k->pruned = 1;
                                break;
                            }
                        }
                        n++;
                    }
                }
            }
            if (e->NextEntryOffset == 0) break;
            size_t used = offsetof(FILE_ID_BOTH_DIR_INFO, FileName) + e->FileNameLength;
            if ((e->NextEntryOffset % sizeof(LONGLONG)) != 0
                || e->NextEntryOffset < used
                || e->NextEntryOffset > bufsz - off) {
                overrun = 1;
                break;
            }
            off += e->NextEntryOffset;
        }
        if (overrun) break;
        ok = GetFileInformationByHandleEx(h, FileIdBothDirectoryInfo, buf, (DWORD)bufsz);
    } while (ok);

    DWORD last = GetLastError();
    free(buf);
    if (!overrun && last != ERROR_NO_MORE_FILES) {
        /* A directory that stopped answering half way through has given us a
         * partial list, and a partial list presented as a whole one is the
         * failure mode this verb exists to end. Keep what we have AND record the
         * failure -- the children are real, and so is the truncation. */
        dirs_fault(w, it->path, last);
    }
    if (overrun) dirs_fault(w, it->path, ERROR_INVALID_DATA);
    /* ONE ROW PER LOST DIRECTORY, so the count is recoverable and not merely the
     * fact that something was lost. Neither loop is reachable except under
     * memory pressure or from a filesystem contradicting its own info class, and
     * neither is therefore reachable from a gate -- which is exactly why the
     * rows are written rather than argued about. */
    for (size_t i = 0; i < bad_name; i++) dirs_fault(w, it->path, ERROR_NO_UNICODE_TRANSLATION);
    for (size_t i = 0; i < lost; i++)     dirs_fault(w, it->path, ERROR_NOT_ENOUGH_MEMORY);

    if (n > 1) qsort(kids, n, sizeof(DirsChild), dirs_namecmp);
    *out = kids;
    *outn = n;
    return 1;
}

/* The walk. Iterative over a heap stack, never recursive: a tree deep enough to
 * matter is a tree deep enough to end the process, and `depth` is a contract
 * value rather than a C stack frame count.
 *
 * EMISSION PRECEDES EVERY POLICY DECISION, and that single ordering is what
 * makes the accounting hold. Pop, write the line, count it -- then decide about
 * descending. Nothing that reached the stack can be prevented from being listed,
 * so every skip in this program is a DESCENT skip and never a LISTING skip, and
 * the caller can always ask "why is this subtree absent" and get an answer from
 * a counter rather than a shrug. */
static int dirs_walk(DirsWalk *w, const wchar_t *rootw, int rootreparse, DWORD roottag) {
    DirsItem *stack = NULL;
    size_t n = 0, cap = 0;

    cap = 64;
    stack = (DirsItem *)malloc(cap * sizeof(DirsItem));
    if (stack == NULL) return 0;
    stack[0].path = _wcsdup(rootw);
    stack[0].depth = 0;
    /* THE ROOT'S OWN REPARSE IDENTITY IS PASSED IN, and it has to be, because
     * nothing inside this loop can work it out: the classification block below
     * is gated on `depth > 0` (the root is exempt from the veto -- you named it,
     * so you get it) and it was therefore also exempt from being DESCRIBED. The
     * result was a junction root walking its target with `links` EMPTY: root,
     * paths, dirs and errors all clean and plausible, and nothing anywhere in
     * the answer saying every path in it is a second name for a tree that lives
     * somewhere else. That is the exact silence this file exists to abolish,
     * appearing in the mechanism built to prevent it. */
    stack[0].reparse = rootreparse;
    stack[0].tag = rootreparse ? roottag : 0;
    stack[0].surrogate = rootreparse ? ((roottag & DIRS_SURROGATE) != 0) : 0;
    stack[0].noenter = rootreparse ? dirs_isname(roottag) : 0;
    stack[0].pruned = 0;
    if (stack[0].path == NULL) { free(stack); return 0; }
    n = 1;

    while (n > 0) {
        DirsItem it = stack[--n];

        char *shown = dirs_strip(it.path, w->unc);
        if (shown != NULL) {
            /* COUNTED IN BOTH MODES, LISTED IN ONLY ONE. `links` has no use for
             * 300,000 path strings and would pay for every one of them; the
             * count is what its report needs, and the emission-precedes-policy
             * rule this loop rests on is about COUNTING, which is unchanged. */
            if (w->mode == DIRS_MODE_DIRS) {
                Tcl_ListObjAppendElement(NULL, w->paths, Tcl_NewStringObj(shown, -1));
            }
            w->count++;
        } else {
            /* Neither listed, nor counted, nor explained -- the one loss class
             * in this file that used to produce NO row at all. Every child that
             * reached this stack had a representable name (see u16_to_u8n), so
             * the only way here is an allocation failure. */
            dirs_fault(w, it.path, ERROR_NOT_ENOUGH_MEMORY);
        }
        if (it.depth > w->maxdepth) w->maxdepth = it.depth;

        const char *action = "descended";
        int stop = 0;
        int entered = 0;
        HANDLE h = INVALID_HANDLE_VALUE;

        /* The order of these three is the order the caller reads them in: a
         * directory refused for depth is not also reported as pruned. */
        if (!stop && w->depthcap >= 0 && it.depth >= w->depthcap) {
            w->depthlimited++;
            action = "depthlimited";
            stop = 1;
        }
        if (!stop && it.pruned) {
            w->pruned++;
            action = "pruned";
            stop = 1;
        }
        /* The parent's scan already said this is a surrogate. Believing it here
         * costs nothing and can only ever refuse a descent -- the direction that
         * is safe to be wrong in -- and it keeps the common case (a junction) at
         * zero handles opened. The dangerous direction, a scan that says "plain
         * directory" about something that has since become a junction, is caught
         * below on the handle. THE ROOT IS EXEMPT: you named it, so you get it,
         * junction or not, and a junction root is a perfectly ordinary way to
         * ask about a tree. */
        if (!stop && it.noenter && it.depth > 0) {
            action = "nofollow";
            stop = 1;
        }

        if (!stop) {
            h = dirs_open(it.path, it.depth == 0);
            if (h == INVALID_HANDLE_VALUE) {
                dirs_fault(w, it.path, GetLastError());
                /* `failed`, NOT the `descended` this used to be left at. A
                 * reparse row whose open failed said "descended" beside an
                 * errors row saying it had not -- an audit trail that
                 * contradicts itself is worth no more than none. */
                action = "failed";
                stop = 1;
            }
        }
        if (!stop && it.depth > 0) {
            FILE_ATTRIBUTE_TAG_INFO ati;
            memset(&ati, 0, sizeof ati);
            if (GetFileInformationByHandleEx(h, FileAttributeTagInfo, &ati, sizeof ati)
                && (ati.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
                it.reparse = 1;
                it.tag = ati.ReparseTag;
                it.surrogate = (it.tag & DIRS_SURROGATE) != 0;
                it.noenter = dirs_isname(it.tag);
                CloseHandle(h);
                h = INVALID_HANDLE_VALUE;
                if (it.noenter) {
                    action = "nofollow";
                    stop = 1;
                } else {
                    /* Content behind a filter. Re-open FOLLOWING the reparse
                     * point, because the handle we hold is the raw one and would
                     * enumerate the reparse data rather than the directory. The
                     * second open is the only place a swap could still slip
                     * through, it costs one open per cloud-style directory
                     * rather than one per directory, and it is recorded here as
                     * a known narrow window rather than left to be discovered. */
                    h = dirs_open(it.path, 1);
                    if (h == INVALID_HANDLE_VALUE) {
                        dirs_fault(w, it.path, GetLastError());
                        action = "failed";
                        stop = 1;
                    }
                }
            }
        }

        if (!stop) {
            DirsChild *kids = NULL;
            size_t kn = 0;
            int got = dirs_children(w, h, &it, &kids, &kn);
            CloseHandle(h);
            h = INVALID_HANDLE_VALUE;
            /* Opening a directory is not yet entering it for this result
             * contract: `entered` means its directory stream was successfully
             * obtained. A failed first enumeration already has an error row;
             * mark the reparse decision failed as well instead of returning a
             * contradictory `descended` row. */
            if (got) entered = 1;
            else action = "failed";
            if (got && kn > 0) {
                if (n + kn > cap) {
                    size_t ncap = cap;
                    while (ncap < n + kn) ncap *= 2;
                    DirsItem *g = (DirsItem *)realloc(stack, ncap * sizeof(DirsItem));
                    if (g != NULL) { stack = g; cap = ncap; }
                }
                /* Pushed in REVERSE so they pop ascending, which is what makes
                 * the emitted sequence depth-first pre-order in sibling order. */
                size_t plen = wcslen(it.path);
                size_t dropped = 0;
                for (size_t i = kn; i-- > 0; ) {
                    /* The stack realloc above failed, so there is no room for
                     * the rest of this directory. It used to `break` here and
                     * discard the remaining siblings in silence -- a truncated
                     * directory reported as a whole one. */
                    if (n == cap) { dropped += i + 1; break; }
                    DirsChild *k = &kids[i];
                    wchar_t *cp = dirs_join(it.path, plen, k->wname, k->wlen);
                    if (cp == NULL) { dropped++; continue; }
                    stack[n].path = cp;
                    stack[n].depth = it.depth + 1;
                    stack[n].reparse = k->reparse;
                    stack[n].tag = k->tag;
                    stack[n].surrogate = k->surrogate;
                    stack[n].noenter = k->noenter;
                    stack[n].pruned = k->pruned;
                    n++;
                }
                for (size_t i = 0; i < dropped; i++) {
                    dirs_fault(w, it.path, ERROR_NOT_ENOUGH_MEMORY);
                }
            }
            for (size_t i = 0; i < kn; i++) { free(kids[i].name); free(kids[i].wname); }
            free(kids);
        }
        if (h != INVALID_HANDLE_VALUE) { CloseHandle(h); h = INVALID_HANDLE_VALUE; }

        /* Every reparse directory gets a row, surrogate or not, making the
         * decision to stop or descend visible to the caller. */
        if (it.reparse) {
            Tcl_ListObjAppendElement(NULL, w->links,
                dirs_link_row(shown ? shown : "", it.tag, it.surrogate, action));
            /* DIRECTORY surrogates are recorded HERE and file surrogates in
             * dirs_children, because a directory reaches the stack and a file
             * never does. Gated on `dirs_isname` rather than on the surrogate
             * bit so the two DFS tags are named as links too. */
            if (w->mode == DIRS_MODE_LINKS && dirs_isname(it.tag)) {
                links_record(w, it.path, shown, it.tag, 1);
            }
            /* `entered` is deliberately narrower than "followable": a depth
             * cap, prune rule, failed open, or failed first enumeration did
             * not enter this directory and must not claim that it did. */
            if (w->mode == DIRS_MODE_LINKS && !dirs_isname(it.tag) && entered) {
                Tcl_ListObjAppendElement(NULL, w->entered,
                    dirs_link_row(shown ? shown : "", it.tag, it.surrogate, action));
            }
        }
        free(shown);
        free(it.path);
    }
    free(stack);
    return 1;
}

static Tcl_Obj *dirs_dict(DirsWalk *w, Tcl_Obj *root) {
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("root", -1), root);
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("paths", -1), w->paths);
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("dirs", -1), Tcl_NewWideIntObj(w->count));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("links", -1), w->links);
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("errors", -1), w->errors);
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("pruned", -1), Tcl_NewWideIntObj(w->pruned));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("depthlimited", -1), Tcl_NewWideIntObj(w->depthlimited));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("maxdepth", -1), Tcl_NewWideIntObj(w->maxdepth));
    /* This result adopts only the dirs-mode lists; release the three links-mode
     * lists allocated by the shared initializer. */
    Tcl_DecrRefCount(w->entries);
    Tcl_DecrRefCount(w->multi);
    Tcl_DecrRefCount(w->entered);
    return d;
}

/* Normalise, then prefix. THE ORDER IS LOAD-BEARING: \\?\ turns off every piece
 * of path normalisation the object manager would otherwise do -- no `.` or `..`,
 * no forward slashes, no trailing-dot trimming -- so prefixing an unnormalised
 * path is the standard route to ERROR_INVALID_NAME. GetFullPathNameW first, the
 * prefix second.
 *
 * WHAT THE PREFIX BUYS, measured: without it, 7 directories in C:\dev at path
 * lengths 278-424 fail with ERROR_PATH_NOT_FOUND and the walk reports 21,760
 * where the prefixed walk reports 21,767 -- an undercount with a clean exit,
 * which is this verb's whole enemy. Go's os package applies the prefix for you
 * above 248 characters; in C that freebie does not exist. Neither the
 * longPathAware manifest flag nor the LongPathsEnabled policy helps, because both
 * only affect the path you did NOT prefix. */
static int dirs_prefix(Tcl_Interp *interp, const char *given, wchar_t **out, int *unc) {
    *out = NULL;
    *unc = 0;
    if (given[0] == '\0') return dirs_error(interp, "badvalue", "the root must not be empty");
    /* A drive-relative root (`C:` or `C:sub`) depends on hidden per-drive
     * process state, so require an explicit absolute spelling. */
    if (((given[0] >= 'A' && given[0] <= 'Z') || (given[0] >= 'a' && given[0] <= 'z'))
        && given[1] == ':' && given[2] != '\\' && given[2] != '/') {
        return dirs_error(interp, "badvalue",
            "a drive-relative root resolves against hidden per-drive state -- write C:/ instead of C:");
    }
    if ((given[0] == '\\' && given[1] == '\\' && given[2] == '.' && given[3] == '\\')
        || (given[0] == '/' && given[1] == '/' && given[2] == '.' && given[3] == '/')) {
        return dirs_error(interp, "badvalue", "a device path is not a directory tree");
    }

    wchar_t *raw = u8_to_u16(given);
    if (raw == NULL) return dirs_error(interp, "badvalue", "the root is not valid text");

    wchar_t *full = NULL;
    /* THE PREFIX IS RECOGNISED BEFORE AND AGAIN AFTER NORMALISATION, and both are
     * needed. Before, because GetFullPathNameW must not run on an already-
     * prefixed path. After, because the FORWARD-SLASH spelling //?/C:/dev is not
     * this test and GetFullPathNameW turns it into \\?\C:\dev -- at which point
     * the `\\` test below reads it as a UNC name and builds \\?\UNC\?\C:\dev,
     * a path that has never existed, refused as `notfound`. Silently wrong
     * construction, not a rejected spelling. */
    int already = (raw[0] == L'\\' && raw[1] == L'\\' && raw[2] == L'?' && raw[3] == L'\\');
    if (already) {
        /* A caller who already spelled the prefix gets it back untouched --
         * GetFullPathNameW returns such a path unchanged anyway, so prefixing it
         * a second time would produce \\?\\\?\C:\... */
        full = raw;
    } else {
        /* A COMPONENT ENDING IN `.` OR A SPACE IS REWRITTEN BY NORMALISATION,
         * SILENTLY, AND THE RESULT CAN BE A DIFFERENT DIRECTORY. Measured:
         * `dirs X/...` returned X's OWN tree -- root reported as X, six
         * directories, no error, no row -- because GetFullPathNameW trims
         * trailing dots and `...` collapses to nothing. `X/trailspace ` and
         * `X/traildot.` at least fail loudly with `notfound`, which is luck
         * rather than design: the walker CREATES and LISTS all four names
         * happily, so this is the verb's own output failing to round-trip.
         * `.` and `..` are the two components where the trailing dots are the
         * whole meaning, and they are exempt. */
        for (const wchar_t *c = raw, *seg = raw; ; c++) {
            if (*c == L'\\' || *c == L'/' || *c == L'\0') {
                size_t sl = (size_t)(c - seg);
                int dotted = (sl == 1 && seg[0] == L'.') || (sl == 2 && seg[0] == L'.' && seg[1] == L'.');
                if (sl > 0 && !dotted && (c[-1] == L'.' || c[-1] == L' ')) {
                    free(raw);
                    return dirs_error(interp, "badvalue",
                        "a path component ending in '.' or a space is rewritten by Win32 "
                        "normalisation and would name a different directory -- spell the root "
                        "\\\\?\\C:\\... to reach it");
                }
                if (*c == L'\0') break;
                seg = c + 1;
            }
        }
        DWORD need = GetFullPathNameW(raw, 0, NULL, NULL);
        if (need == 0) { free(raw); return dirs_error(interp, "badvalue", "the root is not a usable path"); }
        full = (wchar_t *)malloc((size_t)need * sizeof(wchar_t));
        if (full == NULL) { free(raw); return dirs_error(interp, "badvalue", "out of memory"); }
        /* `>= need` AS WELL AS `== 0`. When the buffer is too small this returns
         * the REQUIRED size and writes nothing, so treating every non-zero
         * return as success leaves `full` uninitialised and wcslen below reads
         * raw heap. Reachable if the process current directory grows between the
         * two calls, which a relative root makes possible. */
        DWORD got = GetFullPathNameW(raw, need, full, NULL);
        if (got == 0 || got >= need) {
            free(raw); free(full);
            return dirs_error(interp, "badvalue", "the root is not a usable path");
        }
        free(raw);
        already = (full[0] == L'\\' && full[1] == L'\\' && full[2] == L'?' && full[3] == L'\\');
    }

    /* A TRAILING SEPARATOR MUST COME OFF BEFORE THE ROOT IS REPORTED.
     * GetFullPathNameW preserves it -- `C:/dev/` normalises to `C:\dev\` -- and
     * `dirs C:/dev/` would otherwise answer `root C:/dev/`, one spelling of the
     * root for the caller who wrote a separator and another for the caller who
     * did not. (The comment here used to claim the join would also build
     * \\?\C:\dev\\build and fail every child with 123. Measured: it does not.
     * `dirs_join` adds a separator only when the parent lacks one, so the two
     * are belt-and-braces and the strip's actual job is the reported root.)
     *
     * The one place a trailing backslash must STAY is a drive root: \\?\C: is
     * the volume DEVICE and \\?\C:\ is its root directory. That holds for BOTH
     * spellings -- `C:\` with the colon at index 1, and `\\?\C:\` with it at
     * index 5 -- and testing only the first handed the walk the device: measured,
     * `dirs \\?\C:\` came back `notfound` on a drive that plainly exists, and
     * the prefixed spelling is the only escape hatch a caller has for the names
     * refused above. */
    size_t fl = wcslen(full);
    while (fl > 1 && full[fl - 1] == L'\\') {
        int driveroot = (fl == 3 && full[1] == L':')
                     || (already && fl == 7 && full[5] == L':');
        if (driveroot) break;
        full[--fl] = L'\0';
    }

    wchar_t *pref = NULL;
    if (already) {
        pref = full;
        *unc = (_wcsnicmp(full, L"\\\\?\\UNC\\", 8) == 0);
    } else if (full[0] == L'\\' && full[1] == L'\\') {
        /* \\server\share\x -> \\?\UNC\server\share\x: one leading backslash is
         * dropped and UNC\ takes its place, so the prefix is eight characters
         * standing in for two. dirs_strip undoes exactly this. */
        pref = (wchar_t *)malloc((fl + 8) * sizeof(wchar_t));
        if (pref == NULL) { free(full); return dirs_error(interp, "badvalue", "out of memory"); }
        wcscpy(pref, L"\\\\?\\UNC");
        wcscat(pref, full + 1);
        free(full);
        *unc = 1;
    } else {
        pref = (wchar_t *)malloc((fl + 5) * sizeof(wchar_t));
        if (pref == NULL) { free(full); return dirs_error(interp, "badvalue", "out of memory"); }
        wcscpy(pref, L"\\\\?\\");
        wcscat(pref, full);
        free(full);
    }
    *out = pref;
    return TCL_OK;
}

/* Result lists start at refcount zero and are adopted only by the final result
 * dict. Every earlier return must release them explicitly. */
/* SEPARATE FROM dirs_free, because the prune copy has to be released on the
 * SUCCESS path too -- where the five result lists must NOT be, three of them
 * having been adopted by the dict. Called from both. */
static void dirs_freeprune(DirsWalk *w) {
    if (w->pruneobj != NULL) {
        Tcl_DecrRefCount(w->pruneobj);
        w->pruneobj = NULL;
    }
    w->prunec = 0;
    w->prunev = NULL;
}

static void dirs_free(DirsWalk *w) {
    Tcl_DecrRefCount(w->paths);
    Tcl_DecrRefCount(w->links);
    Tcl_DecrRefCount(w->errors);
    Tcl_DecrRefCount(w->entries);
    Tcl_DecrRefCount(w->multi);
    Tcl_DecrRefCount(w->entered);
    dirs_freeprune(w);
}

/* `links` RETURNS A DIFFERENT ANSWER FROM THE SAME WALK. Not `paths` -- a
 * caller asking which links are under a tree does not want 300,000 path strings
 * and the memory to hold them, which is why the walk skips building that list in
 * this mode rather than building it and dropping it here. */
static Tcl_Obj *links_dict(DirsWalk *w, Tcl_Obj *root) {
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("root", -1), root);
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("links", -1), w->entries);
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("multilinked", -1), w->multi);
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("entered", -1), w->entered);
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("dirs", -1), Tcl_NewWideIntObj(w->count));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("files", -1), Tcl_NewWideIntObj(w->files));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("errors", -1), w->errors);
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("pruned", -1), Tcl_NewWideIntObj(w->pruned));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("depthlimited", -1), Tcl_NewWideIntObj(w->depthlimited));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("maxdepth", -1), Tcl_NewWideIntObj(w->maxdepth));
    /* The two lists this mode does not use are still owned by the walk and are
     * released here, because only the dict adopts what it is given. */
    Tcl_DecrRefCount(w->paths);
    Tcl_DecrRefCount(w->links);
    return d;
}

/* Common key/value options are shared; `links` has a separate outer parser for
 * its value-less `-hardlinks` switch. */
static int dirs_opt_kv(Tcl_Interp *interp, const char *a, Tcl_Obj *v, DirsWalk *w) {
    if (strcmp(a, "-depth") == 0) {
        Tcl_WideInt d;
        if (Tcl_GetWideIntFromObj(NULL, v, &d) != TCL_OK || d < 0 || d > 0x7fffffff) {
            /* NEGATIVE IS NOT "UNLIMITED" AND NEITHER IS ZERO. Unlimited is
             * spelled by leaving the option out; -depth 0 emits the root alone.
             * A sentinel that turns a typo into a thousand-fold difference in
             * what you get back is the `-timeout 100` mistake, and this verb's
             * answer is a whole drive. */
            return dirs_error(interp, "badvalue", "-depth takes a non-negative integer");
        }
        w->depthcap = (int)d;
        return TCL_OK;
    }
    if (strcmp(a, "-prune") == 0) {
        /* Tcl's OWN matcher, so `-prune` speaks `string match` and not a private
         * pattern dialect nobody can look up -- the exact trap `glob`'s pattern
         * language set for the three Tcl attempts. Case-insensitive, against the
         * base name only.
         *
         * DUPLICATED FIRST. The elements below point into the list's internal
         * representation, and the caller's object is not ours to rely on: the
         * same Tcl_Obj passed to `-depth` in the same command shimmers to a
         * number and takes the ListStore with it. A private copy with our own
         * reference is unshimmerable for the walk's lifetime. */
        if (w->pruneobj != NULL) { Tcl_DecrRefCount(w->pruneobj); w->pruneobj = NULL; }
        w->pruneobj = Tcl_DuplicateObj(v);
        Tcl_IncrRefCount(w->pruneobj);
        if (Tcl_ListObjGetElements(NULL, w->pruneobj, &w->prunec, &w->prunev) != TCL_OK) {
            w->prunec = 0;
            w->prunev = NULL;
            return dirs_error(interp, "badvalue", "-prune takes a list of patterns");
        }
        return TCL_OK;
    }
    return dirs_error(interp, "usage", "unknown option");
}

static int dirs_parse(Tcl_Interp *interp, int objc, Tcl_Obj *const objv[], DirsWalk *w) {
    for (int i = 2; i < objc; i++) {
        const char *a = Tcl_GetString(objv[i]);
        if (i + 1 >= objc) return dirs_error(interp, "usage", "option needs a value");
        if (dirs_opt_kv(interp, a, objv[++i], w) != TCL_OK) return TCL_ERROR;
    }
    return TCL_OK;
}

/* Only `links` accepts `-hardlinks`; it buys one extra handle per file. */
static int links_parse(Tcl_Interp *interp, int objc, Tcl_Obj *const objv[], DirsWalk *w) {
    for (int i = 2; i < objc; i++) {
        const char *a = Tcl_GetString(objv[i]);
        if (strcmp(a, "-hardlinks") == 0) { w->hardlinks = 1; continue; }
        if (i + 1 >= objc) return dirs_error(interp, "usage", "option needs a value");
        if (dirs_opt_kv(interp, a, objv[++i], w) != TCL_OK) return TCL_ERROR;
    }
    return TCL_OK;
}

/* THE SOLE INITIALISER, and it sets every field before anything reads one.
 * proc.c:363-369 records what the alternative cost: a field added to an options
 * struct and not to its initialiser held whatever was on the stack, `child
 * start` read the garbage as "inherit stdio", created no pipes, and
 * dereferenced NULL. */
static void dirs_init(DirsWalk *w, int mode) {
    w->paths = Tcl_NewListObj(0, NULL);
    w->links = Tcl_NewListObj(0, NULL);
    w->errors = Tcl_NewListObj(0, NULL);
    w->count = 0;
    w->pruned = 0;
    w->depthlimited = 0;
    w->maxdepth = 0;
    w->depthcap = -1;
    w->unc = 0;
    w->pruneobj = NULL;
    w->prunec = 0;
    w->prunev = NULL;
    w->mode = mode;
    w->hardlinks = 0;
    w->entries = Tcl_NewListObj(0, NULL);
    w->multi = Tcl_NewListObj(0, NULL);
    w->entered = Tcl_NewListObj(0, NULL);
    w->files = 0;
    w->multilink = 0;
}

/* The walk itself, once the options are in. Takes no argv beyond the root, so
 * no option literal can reach it and neither verb's manifest entry is polluted
 * by the other's. */
static int dirs_core(Tcl_Interp *interp, Tcl_Obj *const objv[], DirsWalk *wp) {
    DirsWalk w = *wp;
    wchar_t *rootw = NULL;
    if (dirs_prefix(interp, Tcl_GetString(objv[1]), &rootw, &w.unc) != TCL_OK) {
        dirs_free(&w); return TCL_ERROR;   /* dirs_prefix has already spoken */
    }

    /* THE ROOT IS VALIDATED ON A HANDLE, BEFORE THE FIRST EMISSION. Two reasons.
     * FILE_FLAG_BACKUP_SEMANTICS opens FILES just as happily as directories --
     * measured, a file root opens fine and only fails at enumeration, with
     * ERROR_INVALID_PARAMETER -- so without this check `dirs somefile.txt` would
     * emit the file as a directory and then report one error row. And
     * GetFileAttributesW is not an option: it and the directory scan DISAGREE on
     * cloud placeholders (00080031 against 00080431), so attributes are taken
     * from a handle or from the scan, never from a third source. */
    FILE_ATTRIBUTE_TAG_INFO rati;
    memset(&rati, 0, sizeof rati);
    HANDLE rh = dirs_open(rootw, 1);
    if (rh == INVALID_HANDLE_VALUE) {
        free(rootw);
        dirs_free(&w); return dirs_error(interp, "notfound", "no such directory");
    }
    BOOL rok = GetFileInformationByHandleEx(rh, FileAttributeTagInfo, &rati, sizeof rati);
    CloseHandle(rh);
    if (!rok || !(rati.FileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
        free(rootw);
        dirs_free(&w); return dirs_error(interp, "notfound", "the root is not a directory");
    }

    /* THE ROOT'S OWN TAG NEEDS ITS OWN OPEN, and the handle above cannot supply
     * it. That one FOLLOWS the reparse point -- it has to, because a junction
     * root is descended -- and a followed handle answers with the TARGET's
     * attributes, whose ReparseTag for a junction is 0. The comment at the top of
     * dirs_walk records what the omission cost. */
    int rootreparse = 0;
    DWORD roottag = 0, rootclassfail = 0;
    HANDLE rrh = dirs_open(rootw, 0);
    if (rrh == INVALID_HANDLE_VALUE) {
        rootclassfail = GetLastError();
    } else {
        FILE_ATTRIBUTE_TAG_INFO rrti;
        memset(&rrti, 0, sizeof rrti);
        if (GetFileInformationByHandleEx(rrh, FileAttributeTagInfo, &rrti, sizeof rrti)) {
            if (rrti.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
                rootreparse = 1;
                roottag = rrti.ReparseTag;
            }
        } else {
            rootclassfail = GetLastError();
        }
        CloseHandle(rrh);
    }
    /* AND IF THE HANDLE SAYS "NOT A REPARSE POINT", ASK THE PARENT'S SCAN --
     * FOR THE DISCLOSURE ONLY, NEVER FOR THE VETO. This file's rule at the top
     * is that the handle's answer vetoes descent and never authorises it, and
     * the measurement it rests on is exactly this case: the OneDrive root reads
     * 0x9000701a from the directory scan and tag 0 through a handle, because the
     * cloud filter consumes its own reparse point on open. Applied to CHILDREN
     * that rule is complete. Applied to the ROOT it was silent: `dirs
     * C:/Users/anafa/OneDrive` came back with `links` EMPTY, so narrowing a walk
     * to the divergent subtree was the one invocation that LOST the disclosure,
     * while `dirs C:/Users/anafa` named the same directory as content. The
     * junction root was fixed once already for the same shape of silence.
     *
     * Nothing here can authorise a descent: the veto is `it.noenter &&
     * it.depth > 0`, so the root is entered either way -- you named it, so you
     * get it. All this can do is add a row. FindFirstFileW fails on a drive root
     * and on a UNC share root, which have no parent entry to read; those are not
     * reparse points, and a failure leaves the answer exactly as it was. */
    if (!rootreparse) {
        WIN32_FIND_DATAW rfd;
        HANDLE rfh = FindFirstFileW(rootw, &rfd);
        if (rfh != INVALID_HANDLE_VALUE) {
            if ((rfd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
                && (rfd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
                rootreparse = 1;
                roottag = rfd.dwReserved0;
            }
            FindClose(rfh);
        }
    }
    /* "Could not be classified" is not "is not a reparse point". A row, so the
     * one case where `links` may be silent about the root says so itself. */
    if (rootclassfail != 0) dirs_fault(&w, rootw, rootclassfail);

    char *shownroot = dirs_strip(rootw, w.unc);
    Tcl_Obj *rootobj = Tcl_NewStringObj(shownroot ? shownroot : "", -1);
    free(shownroot);

    if (!dirs_walk(&w, rootw, rootreparse, roottag)) {
        /* `oserror`, NOT `notfound`. The only way here is a failed allocation
         * for the walk's own stack, and a caller trapping `notfound` would
         * conclude the tree is gone -- a wrong answer produced by the error
         * path of a verb whose subject is wrong answers. */
        free(rootw);
        Tcl_DecrRefCount(rootobj);
        dirs_free(&w);
        return dirs_error(interp, "oserror", "the walk could not be started");
    }
    free(rootw);

    /* The patterns are done with; the result lists are not. */
    dirs_freeprune(&w);
    Tcl_SetObjResult(interp, w.mode == DIRS_MODE_LINKS ? links_dict(&w, rootobj)
                                                       : dirs_dict(&w, rootobj));
    return TCL_OK;
}

static int DirsCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "root ?-depth n? ?-prune patterns?");
        return TCL_ERROR;
    }
    DirsWalk w;
    dirs_init(&w, DIRS_MODE_DIRS);
    if (dirs_parse(interp, objc, objv, &w) != TCL_OK) { dirs_free(&w); return TCL_ERROR; }
    return dirs_core(interp, objv, &w);
}

/* `links` reports every name surrogate and, on request, files with shared bytes.
 * Both use the same walk because reparse tags come with enumeration; only link
 * counts require another handle. */
static int LinksCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "root ?-depth n? ?-prune patterns? ?-hardlinks?");
        return TCL_ERROR;
    }
    DirsWalk w;
    dirs_init(&w, DIRS_MODE_LINKS);
    if (links_parse(interp, objc, objv, &w) != TCL_OK) { dirs_free(&w); return TCL_ERROR; }
    return dirs_core(interp, objv, &w);
}

/* --- `canon`: which object is this path, and where does it really live? -----
 *
 * Tcl's lexical path normalization does not follow a reparse point in the final
 * component, and `file stat` cannot expose Windows' volume/file identity. Open
 * the target with following enabled, then ask that handle for its final path,
 * volume serial, and 64-bit file index. */
static int CanonCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "path");
        return TCL_ERROR;
    }
    wchar_t *pathw = NULL;
    int unc = 0;
    if (dirs_prefix(interp, Tcl_GetString(objv[1]), &pathw, &unc) != TCL_OK) {
        return TCL_ERROR;                  /* dirs_prefix has already spoken */
    }
    /* FOLLOW. This is the whole verb: `dirs` opens with
     * FILE_FLAG_OPEN_REPARSE_POINT so a junction is classified rather than
     * entered, and here the opposite is wanted -- the target is the answer. */
    HANDLE h = dirs_open(pathw, 1);
    if (h == INVALID_HANDLE_VALUE) {
        /* A dangling link is not a missing path. A raw reparse-point open tells
         * us whether the name exists even though the followed open failed. */
        DWORD e = GetLastError();
        HANDLE raw = dirs_open(pathw, 0);
        if (raw != INVALID_HANDLE_VALUE) {
            CloseHandle(raw);
            free(pathw);
            /* Keep this distinct from `notfound`: a resolver may continue past
             * a missing component but must stop at an existing broken link. */
            return dirs_error(interp, "dangling",
                "the path exists but its target cannot be resolved");
        }
        free(pathw);
        return dirs_error(interp, e == ERROR_ACCESS_DENIED ? "oserror" : "notfound",
            e == ERROR_ACCESS_DENIED ? "the path cannot be opened" : "no such path");
    }

    BY_HANDLE_FILE_INFORMATION bhfi;
    memset(&bhfi, 0, sizeof bhfi);
    if (!GetFileInformationByHandle(h, &bhfi)) {
        CloseHandle(h);
        free(pathw);
        return dirs_error(interp, "oserror", "the path could not be identified");
    }
    /* Asked for its length first: a path can be up to 32,767 units and a fixed
     * buffer here is the bug this file's `\\?\` handling exists to avoid. */
    DWORD need = GetFinalPathNameByHandleW(h, NULL, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (need == 0) {
        CloseHandle(h);
        free(pathw);
        return dirs_error(interp, "oserror", "the path could not be canonicalised");
    }
    wchar_t *finalw = (wchar_t *)malloc((size_t)(need + 1) * sizeof(wchar_t));
    if (finalw == NULL) {
        CloseHandle(h);
        free(pathw);
        return dirs_error(interp, "oserror", "out of memory");
    }
    DWORD wrote = GetFinalPathNameByHandleW(h, finalw, need, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(h);
    free(pathw);
    if (wrote == 0 || wrote >= need + 1) {
        free(finalw);
        return dirs_error(interp, "oserror", "the path could not be canonicalised");
    }
    finalw[wrote] = L'\0';

    /* GetFinalPathNameByHandleW always answers with the `\\?\` prefix, in the
     * same two shapes dirs_strip already undoes -- `\\?\C:\x` and `\\?\UNC\s\h`. */
    int func = (wcsncmp(finalw, L"\\\\?\\UNC\\", 8) == 0);
    char *shown = dirs_strip(finalw, func);
    free(finalw);
    if (shown == NULL) return dirs_error(interp, "oserror", "the path is not representable");

    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("path", -1), Tcl_NewStringObj(shown, -1));
    free(shown);
    /* Fixed-width hex strings, not integers. A 64-bit file
     * index does not fit a Tcl_WideInt's signed range on every volume, and a
     * caller comparing identities wants a token to compare rather than a number
     * to do arithmetic on. */
    char vol[24], fil[24];
    snprintf(vol, sizeof vol, "%016llx", (unsigned long long)bhfi.dwVolumeSerialNumber);
    snprintf(fil, sizeof fil, "%016llx",
             ((unsigned long long)bhfi.nFileIndexHigh << 32) | bhfi.nFileIndexLow);
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("volume", -1), Tcl_NewStringObj(vol, -1));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("file", -1), Tcl_NewStringObj(fil, -1));
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("kind", -1), Tcl_NewStringObj(
        (bhfi.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? "directory" : "file", -1));
    /* The link count comes free with the same call, and it is the one fact
     * `links -hardlinks` pays a handle per file for. */
    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("links", -1),
                   Tcl_NewWideIntObj((Tcl_WideInt)bhfi.nNumberOfLinks));
    Tcl_SetObjResult(interp, d);
    return TCL_OK;
}

int Machtelddirs_Init(Tcl_Interp *interp) {
    if (Tcl_CreateObjCommand(interp, "::machteld::dirs", DirsCmd, NULL, NULL) == NULL
        || Tcl_CreateObjCommand(interp, "::machteld::links", LinksCmd, NULL, NULL) == NULL
        || Tcl_CreateObjCommand(interp, "::machteld::canon", CanonCmd, NULL, NULL) == NULL) {
        return TCL_ERROR;
    }
    return Tcl_PkgProvide(interp, "machteld::dirs", MACHTELD_VERSION);
}
