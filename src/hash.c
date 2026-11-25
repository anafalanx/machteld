/*
 * hash.c -- ::machteld::hash: digests, HMAC and cryptographic random.
 *
 * Windows CNG supplies crypto. The statically compiled xxHash library supplies
 * the seed-zero XXH3-64 checksums used by file catalogs.
 *
 * WHICH BYTES GET HASHED -- the decision that actually matters here. A Tcl value
 * is not bytes; it is a value that has a byte representation depending on how you
 * ask. Hashing the Latin-1 view of "cafe<e9>" and hashing its UTF-8 gives two
 * different digests, and only one of them agrees with the rest of the world. So
 * the rule is the same one `json encode` already follows: read what the value
 * IS, never what its text looks like.
 *
 *   - a byte array (from `binary decode`, or a channel read in binary mode)
 *     hashes those bytes exactly;
 *   - anything else hashes its UTF-8 encoding.
 *
 * Type-based, so it cannot be fooled by a string that happens to look binary,
 * and `hash sum sha256 abc` agrees with sha256sum, certutil and every other
 * implementation.
 */
#undef USE_TCL_STUBS
#include "machteld.h"

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>
#define XXH_INLINE_ALL
#include <machteld-vendor/xxhash.h>

#define HASH_CHUNK (64 * 1024)
#define HASH_MAX_DIGEST 64

static int hash_error(Tcl_Interp *interp, const char *code, const char *msg) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
    Tcl_SetErrorCode(interp, "MACHTELD", "HASH", code, (char *)NULL);
    return TCL_ERROR;
}

/* The algorithms this build exposes. Deliberately a table of VALUES rather than
 * a table of subcommands: adding sha3-256 later must not widen the frozen
 * subcommand surface, and `hash algorithms` can then answer honestly at runtime
 * instead of the docs claiming a set the binary might not have. */
typedef struct { const char *name; LPCWSTR id; } alg_t;
static const alg_t ALGS[] = {
    { "md5",    BCRYPT_MD5_ALGORITHM    },
    { "sha1",   BCRYPT_SHA1_ALGORITHM   },
    { "sha256", BCRYPT_SHA256_ALGORITHM },
    { "sha384", BCRYPT_SHA384_ALGORITHM },
    { "sha512", BCRYPT_SHA512_ALGORITHM },
    { "xxh3-64", NULL }, /* A named entry without a CNG provider uses xxHash. */
    { NULL, NULL }
};

static const alg_t *alg_find(const char *name) {
    for (const alg_t *a = ALGS; a->name != NULL; a++) {
        if (strcmp(a->name, name) == 0) return a;
    }
    return NULL;
}

/* One backend owns the state; the xxHash allocator supplies its alignment. */
typedef struct {
    BCRYPT_ALG_HANDLE  alg_h;
    BCRYPT_HASH_HANDLE h;
    XXH3_state_t *xxh;
    DWORD  digest_len;
} digest_t;

typedef struct hctx_s {
    char token[24];
    digest_t digest;
    struct hctx_s *next;
} hctx_t;

typedef struct {
    hctx_t *ctxs;
    int     seq;
} hash_state;

static hctx_t *hctx_find(hash_state *st, const char *token) {
    for (hctx_t *c = st->ctxs; c; c = c->next) {
        if (strcmp(c->token, token) == 0) return c;
    }
    return NULL;
}

static void digest_close(digest_t *digest) {
    if (digest->xxh != NULL) XXH3_freeState(digest->xxh);
    if (digest->h != NULL) BCryptDestroyHash(digest->h);
    if (digest->alg_h != NULL) BCryptCloseAlgorithmProvider(digest->alg_h, 0);
}

static void hctx_free(hash_state *st, hctx_t *c) {
    for (hctx_t **p = &st->ctxs; *p; p = &(*p)->next) {
        if (*p == c) { *p = c->next; break; }
    }
    digest_close(&c->digest);
    free(c);
}

/* The caller zeroes the state and closes it even when initialization fails. */
static int digest_open(Tcl_Interp *interp, digest_t *digest, const alg_t *a,
                       int hmac, const unsigned char *key, Tcl_Size keylen) {
    if (a->id == NULL) {
        if (hmac) return hash_error(interp, "badvalue", "xxh3-64 does not support HMAC");
        digest->xxh = XXH3_createState();
        if (digest->xxh == NULL || XXH3_64bits_reset(digest->xxh) != XXH_OK) {
            return hash_error(interp, "oserror", "cannot create the XXH3 state");
        }
        digest->digest_len = sizeof(XXH64_canonical_t);
        return TCL_OK;
    }
    if (keylen < 0 || (unsigned long long)keylen > ULONG_MAX) {
        return hash_error(interp, "badvalue", "the HMAC key is too large");
    }
    ULONG flags = hmac ? BCRYPT_ALG_HANDLE_HMAC_FLAG : 0;
    if (BCryptOpenAlgorithmProvider(&digest->alg_h, a->id, NULL, flags) != 0) {
        return hash_error(interp, "oserror", "cannot open the crypto provider");
    }
    DWORD n = 0, cb = 0;
    if (BCryptGetProperty(digest->alg_h, BCRYPT_HASH_LENGTH, (PUCHAR)&n, sizeof n, &cb, 0) != 0) {
        return hash_error(interp, "oserror", "cannot read the digest length");
    }
    if (n == 0 || n > HASH_MAX_DIGEST) {
        return hash_error(interp, "oserror", "the crypto provider returned an invalid digest length");
    }
    digest->digest_len = n;
    if (BCryptCreateHash(digest->alg_h, &digest->h, NULL, 0, (PUCHAR)key, (ULONG)keylen, 0) != 0) {
        return hash_error(interp, "oserror", "cannot create the hash object");
    }
    return TCL_OK;
}

static int digest_update(Tcl_Interp *interp, digest_t *digest, const unsigned char *data, Tcl_Size len) {
    /* Keep the public per-update limit consistent across algorithms. */
    if (len < 0 || (unsigned long long)len > ULONG_MAX) {
        return hash_error(interp, "badvalue", "the input is too large");
    }
    if (digest->xxh != NULL) {
        if (XXH3_64bits_update(digest->xxh, data, (size_t)len) == XXH_OK) return TCL_OK;
    } else if (BCryptHashData(digest->h, (PUCHAR)data, (ULONG)len, 0) == 0) {
        return TCL_OK;
    }
    return hash_error(interp, "oserror", "hashing failed");
}

/* The bytes of a Tcl value come from Machteld_ValueBytes (machteld.h), the byte
 * rule shared with store, http post, and -stdin: a byte array is its bytes,
 * anything else is its UTF-8. The measurement that fixed the rule's shape was
 * made here: matched by type pointer instead of type NAME, `binary decode hex
 * 636166c3a9` hashed as seven bytes of UTF-8 instead of five bytes of data. */

static Tcl_Obj *digest_obj(const unsigned char *d, DWORD n, int binary) {
    if (binary) return Tcl_NewByteArrayObj(d, (Tcl_Size)n);
    char *hex = (char *)malloc((size_t)n * 2 + 1);
    if (hex == NULL) return NULL;
    static const char *H = "0123456789abcdef";
    for (DWORD i = 0; i < n; i++) { hex[i*2] = H[d[i] >> 4]; hex[i*2+1] = H[d[i] & 15]; }
    hex[n*2] = '\0';
    Tcl_Obj *o = Tcl_NewStringObj(hex, (Tcl_Size)n * 2);
    free(hex);
    return o;
}

static int digest_result(Tcl_Interp *interp, digest_t *digest, int binary) {
    unsigned char out[HASH_MAX_DIGEST];
    if (digest->xxh != NULL) {
        XXH64_canonical_t canonical;
        XXH64_canonicalFromHash(&canonical, XXH3_64bits_digest(digest->xxh));
        memcpy(out, canonical.digest, sizeof(canonical.digest));
    } else if (BCryptFinishHash(digest->h, out, digest->digest_len, 0) != 0) {
        return hash_error(interp, "oserror", "finishing the hash failed");
    }
    Tcl_Obj *result = digest_obj(out, digest->digest_len, binary);
    if (result == NULL) return hash_error(interp, "oserror", "out of memory");
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
}

/* -binary, shared by sum / file / hmac / final. Returns -1 on a bad option. */
static int want_binary(Tcl_Interp *interp, int objc, Tcl_Obj *const objv[], int from) {
    int binary = 0;
    for (int i = from; i < objc; i++) {
        if (strcmp(Tcl_GetString(objv[i]), "-binary") == 0) { binary = 1; continue; }
        hash_error(interp, "usage", "unknown option");
        return -1;
    }
    return binary;
}

static int HashCmd(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    hash_state *st = (hash_state *)cd;
    static const char *const subs[] = {
        "sum", "file", "hmac", "start", "update", "final", "list", "algorithms", "random", NULL
    };
    enum { SUM, FILE_, HMAC, START, UPDATE, FINAL, LIST, ALGORITHMS, RANDOM };
    int idx;
    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "subcommand ?arg ...?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(interp, objv[1], subs, "subcommand", TCL_EXACT, &idx) != TCL_OK) return TCL_ERROR;

    if (idx == ALGORITHMS) {
        if (objc != 2) { Tcl_WrongNumArgs(interp, 2, objv, ""); return TCL_ERROR; }
        Tcl_Obj *l = Tcl_NewListObj(0, NULL);
        for (const alg_t *a = ALGS; a->name != NULL; a++) {
            Tcl_ListObjAppendElement(interp, l, Tcl_NewStringObj(a->name, -1));
        }
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }

    if (idx == LIST) {
        if (objc != 2) { Tcl_WrongNumArgs(interp, 2, objv, ""); return TCL_ERROR; }
        Tcl_Obj *l = Tcl_NewListObj(0, NULL);
        for (hctx_t *c = st->ctxs; c; c = c->next) {
            Tcl_ListObjAppendElement(interp, l, Tcl_NewStringObj(c->token, -1));
        }
        Tcl_SetObjResult(interp, l);
        return TCL_OK;
    }

    if (idx == RANDOM) {
        if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "count"); return TCL_ERROR; }
        Tcl_WideInt n;
        if (Tcl_GetWideIntFromObj(interp, objv[2], &n) != TCL_OK) {
            return hash_error(interp, "badvalue", "count must be an integer");
        }
        if (n < 1 || n > (1 << 20)) {
            return hash_error(interp, "badvalue", "count must be between 1 and 1048576");
        }
        unsigned char *buf = (unsigned char *)malloc((size_t)n);
        if (buf == NULL) return hash_error(interp, "oserror", "out of memory");
        /* The system-preferred RNG: seeded and reseeded by the OS, unlike
         * expr {rand()}, which is a deterministic PRNG and must never be used
         * for anything that has to be unguessable. */
        if (BCryptGenRandom(NULL, buf, (ULONG)n, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
            free(buf);
            return hash_error(interp, "oserror", "the system random generator failed");
        }
        Tcl_SetObjResult(interp, Tcl_NewByteArrayObj(buf, (Tcl_Size)n));
        free(buf);
        return TCL_OK;
    }

    if (idx == SUM || idx == FILE_ || idx == HMAC || idx == START) {
        if (objc < 3) { Tcl_WrongNumArgs(interp, 2, objv, "algorithm ?arg ...?"); return TCL_ERROR; }
        const char *aname = Tcl_GetString(objv[2]);
        const alg_t *a = alg_find(aname);
        if (a == NULL) {
            Tcl_Obj *m = Tcl_NewStringObj("unknown algorithm \"", -1);
            Tcl_AppendToObj(m, aname, -1);
            Tcl_AppendToObj(m, "\": try `hash algorithms`", -1);
            Tcl_SetObjResult(interp, m);
            Tcl_SetErrorCode(interp, "MACHTELD", "HASH", "badvalue", (char *)NULL);
            return TCL_ERROR;
        }

        if (idx == START) {
            if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "algorithm"); return TCL_ERROR; }
            /* Tokens must never wrap, collide, or invoke signed overflow after
             * a long-lived interpreter has consumed its sequence space. */
            if (st->seq == INT_MAX) {
                return hash_error(interp, "oserror", "hash token sequence exhausted");
            }
            hctx_t *c = (hctx_t *)calloc(1, sizeof(*c));
            if (c == NULL) return hash_error(interp, "oserror", "out of memory");
            if (digest_open(interp, &c->digest, a, 0, NULL, 0) != TCL_OK) {
                digest_close(&c->digest);
                free(c);
                return TCL_ERROR;
            }
            snprintf(c->token, sizeof c->token, "hash#%d", ++st->seq);
            c->next = st->ctxs;
            st->ctxs = c;
            Tcl_SetObjResult(interp, Tcl_NewStringObj(c->token, -1));
            return TCL_OK;
        }

        if (idx == SUM || idx == HMAC) {
            int hmac = idx == HMAC;
            int count = hmac ? 5 : 4;
            if (objc < count) {
                Tcl_WrongNumArgs(interp, 2, objv, hmac ? "algorithm key data ?-binary?" : "algorithm data ?-binary?");
                return TCL_ERROR;
            }
            int binary = want_binary(interp, objc, objv, count);
            if (binary < 0) return TCL_ERROR;
            Tcl_Size klen = 0, n = 0;
            Tcl_DString kds, ds;
            const unsigned char *key = hmac ? Machteld_ValueBytes(objv[3], &klen, &kds) : NULL;
            digest_t digest = {0};
            int rc = digest_open(interp, &digest, a, hmac, key, klen);
            if (hmac) Tcl_DStringFree(&kds);
            if (rc == TCL_OK) {
                const unsigned char *data = Machteld_ValueBytes(objv[count - 1], &n, &ds);
                rc = digest_update(interp, &digest, data, n);
                Tcl_DStringFree(&ds);
            }
            if (rc == TCL_OK) rc = digest_result(interp, &digest, binary);
            digest_close(&digest);
            return rc;
        }

        /* FILE_: streamed in chunks, so hashing a DVD image costs 64 KB of
         * memory rather than its size. Opened through the Tcl channel layer so
         * that zipfs paths and every other VFS work, with -translation binary
         * because a digest of "the file" must not depend on line endings. */
        if (objc < 4) { Tcl_WrongNumArgs(interp, 2, objv, "algorithm path ?-binary?"); return TCL_ERROR; }
        int binary = want_binary(interp, objc, objv, 4);
        if (binary < 0) return TCL_ERROR;
        const char *path = Tcl_GetString(objv[3]);
        Tcl_Channel ch = Tcl_FSOpenFileChannel(interp, objv[3], "rb", 0);
        if (ch == NULL) {
            Tcl_Obj *m = Tcl_NewStringObj("cannot read \"", -1);
            Tcl_AppendToObj(m, path, -1);
            Tcl_AppendToObj(m, "\"", -1);
            Tcl_SetObjResult(interp, m);
            int eno = Tcl_GetErrno();
            Tcl_SetErrorCode(interp, "MACHTELD", "HASH",
                (eno == ENOENT || eno == ENOTDIR) ? "notfound" : "oserror",
                (char *)NULL);
            return TCL_ERROR;
        }
        if (Tcl_SetChannelOption(interp, ch, "-translation", "binary") != TCL_OK) {
            Tcl_Close(NULL, ch);
            return TCL_ERROR;
        }
        digest_t digest = {0};
        if (digest_open(interp, &digest, a, 0, NULL, 0) != TCL_OK) {
            digest_close(&digest);
            Tcl_Close(NULL, ch);
            return TCL_ERROR;
        }
        unsigned char buf[HASH_CHUNK];
        int failed = 0;
        for (;;) {
            Tcl_Size got = Tcl_ReadRaw(ch, (char *)buf, HASH_CHUNK);
            if (got < 0) { failed = 1; break; }
            if (got == 0) break;
            if (digest_update(interp, &digest, buf, got) != TCL_OK) {
                failed = 1;
                break;
            }
        }
        if (Tcl_Close(interp, ch) != TCL_OK) failed = 1;
        int rc = failed ? hash_error(interp, "oserror", "reading the file failed") : digest_result(interp, &digest, binary);
        digest_close(&digest);
        return rc;
    }

    /* UPDATE / FINAL: both take a token. */
    if (objc < 3) { Tcl_WrongNumArgs(interp, 2, objv, "token ?arg?"); return TCL_ERROR; }
    hctx_t *c = hctx_find(st, Tcl_GetString(objv[2]));
    if (c == NULL) return hash_error(interp, "nohandle", "no such hash context");

    if (idx == UPDATE) {
        if (objc != 4) { Tcl_WrongNumArgs(interp, 2, objv, "token data"); return TCL_ERROR; }
        Tcl_Size n = 0;
        Tcl_DString ds;
        const unsigned char *data = Machteld_ValueBytes(objv[3], &n, &ds);
        int rc = digest_update(interp, &c->digest, data, n);
        Tcl_DStringFree(&ds);
        return rc;
    }

    /* FINAL consumes the token: a context cannot be finished twice, and the
     * handle does not outlive the answer. */
    int binary = want_binary(interp, objc, objv, 3);
    if (binary < 0) return TCL_ERROR;
    int rc = digest_result(interp, &c->digest, binary);
    hctx_free(st, c);
    return rc;
}

/* Tcl_CmdDeleteProc takes the client data alone. Contexts left open when the
 * interpreter goes are freed here rather than leaked -- the same bounded-handle
 * discipline child/pty/watch follow. */
static void HashDelete(void *cd) {
    hash_state *st = (hash_state *)cd;
    while (st->ctxs != NULL) hctx_free(st, st->ctxs);
    free(st);
}

int Machteldhash_Init(Tcl_Interp *interp) {
    hash_state *st = (hash_state *)calloc(1, sizeof(*st));
    if (st == NULL) return hash_error(interp, "oserror", "out of memory creating hash state");
    if (Tcl_CreateObjCommand(interp, "::machteld::hash", HashCmd, st,
                             HashDelete) == NULL) {
        free(st);
        return TCL_ERROR;
    }
    if (Tcl_PkgProvide(interp, "machteld::hash", MACHTELD_VERSION) != TCL_OK) {
        Tcl_DeleteCommand(interp, "::machteld::hash");
        return TCL_ERROR;
    }
    return TCL_OK;
}
