/*
 * hash.c -- ::machteld::hash: digests, HMAC and cryptographic random.
 *
 * It uses Windows CNG (bcrypt.dll): no vendored crypto or runtime DLLs.
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
#include <limits.h>
#include <errno.h>

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
    { NULL, NULL }
};

static const alg_t *alg_find(const char *name) {
    for (const alg_t *a = ALGS; a->name != NULL; a++) {
        if (strcmp(a->name, name) == 0) return a;
    }
    return NULL;
}

/* An open incremental context. Stateful, so it is a token with the same lifetime
 * discipline as child#N / pty#N / watch#N -- `list` to see them, and `final`
 * consumes it. */
typedef struct hctx_s {
    char   token[24];
    const alg_t *alg;
    BCRYPT_ALG_HANDLE  alg_h;
    BCRYPT_HASH_HANDLE h;
    DWORD  digest_len;
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

static void hctx_free(hash_state *st, hctx_t *c) {
    for (hctx_t **p = &st->ctxs; *p; p = &(*p)->next) {
        if (*p == c) { *p = c->next; break; }
    }
    if (c->h != NULL) BCryptDestroyHash(c->h);
    if (c->alg_h != NULL) BCryptCloseAlgorithmProvider(c->alg_h, 0);
    free(c);
}

/* Open a provider and a hash object. `key` non-NULL makes it an HMAC. */
static int alg_open(Tcl_Interp *interp, const alg_t *a, const unsigned char *key, Tcl_Size keylen,
                    BCRYPT_ALG_HANDLE *alg_h, BCRYPT_HASH_HANDLE *h, DWORD *dlen) {
    ULONG flags = (key != NULL) ? BCRYPT_ALG_HANDLE_HMAC_FLAG : 0;
    if (BCryptOpenAlgorithmProvider(alg_h, a->id, NULL, flags) != 0) {
        return hash_error(interp, "oserror", "cannot open the crypto provider");
    }
    DWORD n = 0, cb = 0;
    if (BCryptGetProperty(*alg_h, BCRYPT_HASH_LENGTH, (PUCHAR)&n, sizeof n, &cb, 0) != 0) {
        BCryptCloseAlgorithmProvider(*alg_h, 0);
        return hash_error(interp, "oserror", "cannot read the digest length");
    }
    if (n == 0 || n > HASH_MAX_DIGEST) {
        BCryptCloseAlgorithmProvider(*alg_h, 0);
        return hash_error(interp, "oserror", "the crypto provider returned an invalid digest length");
    }
    *dlen = n;
    if (keylen < 0 || (unsigned long long)keylen > ULONG_MAX) {
        BCryptCloseAlgorithmProvider(*alg_h, 0);
        return hash_error(interp, "badvalue", "the HMAC key is too large");
    }
    if (BCryptCreateHash(*alg_h, h, NULL, 0, (PUCHAR)key, (ULONG)keylen, 0) != 0) {
        BCryptCloseAlgorithmProvider(*alg_h, 0);
        return hash_error(interp, "oserror", "cannot create the hash object");
    }
    return TCL_OK;
}

/* The bytes of a Tcl value, per the rule at the top of this file: a byte array
 * is its bytes, anything else is its UTF-8.
 *
 * MATCHED BY TYPE NAME, NOT BY TYPE POINTER. Tcl 9 carries two byte-array object
 * types and registers only one of them under the name "bytearray", so comparing
 * `v->typePtr` against `Tcl_GetObjType("bytearray")` returns false for the values
 * `binary decode` actually produces. That is the precise case which must not be
 * re-encoded, and the failure is silent: the bytes fall through to the string
 * path, each one is read as a character, and `binary decode hex 636166c3a9`
 * hashes as seven bytes of UTF-8 instead of five bytes of data.
 *
 * Tcl_GetBytesFromObj cannot be used as the test either -- it is a coercion, not
 * a predicate, and it happily converts the string "cafe<e9>" to four Latin-1
 * bytes. The type NAME is the one thing that is both public and true. */
static const unsigned char *value_bytes(Tcl_Obj *v, Tcl_Size *len) {
    const Tcl_ObjType *t = v->typePtr;
    if (t != NULL && t->name != NULL && strcmp(t->name, "bytearray") == 0) {
        unsigned char *b = Tcl_GetBytesFromObj(NULL, v, len);
        if (b != NULL) return b;
    }
    return (const unsigned char *)Tcl_GetStringFromObj(v, len);
}

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
            hctx_t *c = (hctx_t *)calloc(1, sizeof(*c));
            if (c == NULL) return hash_error(interp, "oserror", "out of memory");
            if (alg_open(interp, a, NULL, 0, &c->alg_h, &c->h, &c->digest_len) != TCL_OK) {
                free(c);
                return TCL_ERROR;
            }
            c->alg = a;
            snprintf(c->token, sizeof c->token, "hash#%d", ++st->seq);
            c->next = st->ctxs;
            st->ctxs = c;
            Tcl_SetObjResult(interp, Tcl_NewStringObj(c->token, -1));
            return TCL_OK;
        }

        if (idx == HMAC) {
            if (objc < 5) { Tcl_WrongNumArgs(interp, 2, objv, "algorithm key data ?-binary?"); return TCL_ERROR; }
            int binary = want_binary(interp, objc, objv, 5);
            if (binary < 0) return TCL_ERROR;
            Tcl_Size klen = 0, dlen_in = 0;
            const unsigned char *key = value_bytes(objv[3], &klen);
            const unsigned char *data = value_bytes(objv[4], &dlen_in);
            if (dlen_in < 0 || (unsigned long long)dlen_in > ULONG_MAX) {
                return hash_error(interp, "badvalue", "the input is too large");
            }
            BCRYPT_ALG_HANDLE ah; BCRYPT_HASH_HANDLE hh; DWORD dn;
            if (alg_open(interp, a, key, klen, &ah, &hh, &dn) != TCL_OK) return TCL_ERROR;
            unsigned char out[64];
            int ok = (BCryptHashData(hh, (PUCHAR)data, (ULONG)dlen_in, 0) == 0) &&
                     (BCryptFinishHash(hh, out, dn, 0) == 0);
            BCryptDestroyHash(hh); BCryptCloseAlgorithmProvider(ah, 0);
            if (!ok) return hash_error(interp, "oserror", "hmac failed");
            Tcl_Obj *result = digest_obj(out, dn, binary);
            if (result == NULL) return hash_error(interp, "oserror", "out of memory");
            Tcl_SetObjResult(interp, result);
            return TCL_OK;
        }

        if (idx == SUM) {
            if (objc < 4) { Tcl_WrongNumArgs(interp, 2, objv, "algorithm data ?-binary?"); return TCL_ERROR; }
            int binary = want_binary(interp, objc, objv, 4);
            if (binary < 0) return TCL_ERROR;
            Tcl_Size n = 0;
            const unsigned char *data = value_bytes(objv[3], &n);
            if (n < 0 || (unsigned long long)n > ULONG_MAX) {
                return hash_error(interp, "badvalue", "the input is too large");
            }
            BCRYPT_ALG_HANDLE ah; BCRYPT_HASH_HANDLE hh; DWORD dn;
            if (alg_open(interp, a, NULL, 0, &ah, &hh, &dn) != TCL_OK) return TCL_ERROR;
            unsigned char out[64];
            int ok = (BCryptHashData(hh, (PUCHAR)data, (ULONG)n, 0) == 0) &&
                     (BCryptFinishHash(hh, out, dn, 0) == 0);
            BCryptDestroyHash(hh); BCryptCloseAlgorithmProvider(ah, 0);
            if (!ok) return hash_error(interp, "oserror", "hashing failed");
            Tcl_Obj *result = digest_obj(out, dn, binary);
            if (result == NULL) return hash_error(interp, "oserror", "out of memory");
            Tcl_SetObjResult(interp, result);
            return TCL_OK;
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
        BCRYPT_ALG_HANDLE ah; BCRYPT_HASH_HANDLE hh; DWORD dn;
        if (alg_open(interp, a, NULL, 0, &ah, &hh, &dn) != TCL_OK) {
            Tcl_Close(NULL, ch);
            return TCL_ERROR;
        }
        unsigned char buf[HASH_CHUNK];
        int failed = 0;
        for (;;) {
            Tcl_Size got = Tcl_ReadRaw(ch, (char *)buf, HASH_CHUNK);
            if (got < 0) { failed = 1; break; }
            if (got == 0) break;
            if (BCryptHashData(hh, buf, (ULONG)got, 0) != 0) {
                failed = 1;
                break;
            }
        }
        if (Tcl_Close(interp, ch) != TCL_OK) failed = 1;
        unsigned char out[64];
        if (failed || BCryptFinishHash(hh, out, dn, 0) != 0) {
            BCryptDestroyHash(hh); BCryptCloseAlgorithmProvider(ah, 0);
            return hash_error(interp, "oserror", "reading the file failed");
        }
        BCryptDestroyHash(hh); BCryptCloseAlgorithmProvider(ah, 0);
        Tcl_Obj *result = digest_obj(out, dn, binary);
        if (result == NULL) return hash_error(interp, "oserror", "out of memory");
        Tcl_SetObjResult(interp, result);
        return TCL_OK;
    }

    /* UPDATE / FINAL: both take a token. */
    if (objc < 3) { Tcl_WrongNumArgs(interp, 2, objv, "token ?arg?"); return TCL_ERROR; }
    hctx_t *c = hctx_find(st, Tcl_GetString(objv[2]));
    if (c == NULL) return hash_error(interp, "nohandle", "no such hash context");

    if (idx == UPDATE) {
        if (objc != 4) { Tcl_WrongNumArgs(interp, 2, objv, "token data"); return TCL_ERROR; }
        Tcl_Size n = 0;
        const unsigned char *data = value_bytes(objv[3], &n);
        if (n < 0 || (unsigned long long)n > ULONG_MAX) {
            return hash_error(interp, "badvalue", "the input is too large");
        }
        if (BCryptHashData(c->h, (PUCHAR)data, (ULONG)n, 0) != 0) {
            return hash_error(interp, "oserror", "hashing failed");
        }
        return TCL_OK;
    }

    /* FINAL consumes the token: a context cannot be finished twice, and the
     * handle does not outlive the answer. */
    int binary = want_binary(interp, objc, objv, 3);
    if (binary < 0) return TCL_ERROR;
    unsigned char out[64];
    DWORD dn = c->digest_len;
    int ok = (BCryptFinishHash(c->h, out, dn, 0) == 0);
    hctx_free(st, c);
    if (!ok) return hash_error(interp, "oserror", "finishing the hash failed");
    Tcl_Obj *result = digest_obj(out, dn, binary);
    if (result == NULL) return hash_error(interp, "oserror", "out of memory");
    Tcl_SetObjResult(interp, result);
    return TCL_OK;
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
