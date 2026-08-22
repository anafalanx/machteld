/* engine_json.h -- strict, bounded JSON for the engine's control plane.
 *
 * The engine process runs no Tcl and (deliberately) does not lean on kernel
 * libraries for its own wire: this is a small, independent, auditable codec
 * sized to protocol 1 of docs/engine.md. Parse produces a read-only value
 * tree that is safe to SHARE ACROSS THREADS for reading; encode is an
 * append-only buffer. No dependency beyond the C runtime.
 */
#ifndef MACHTELD_ENGINE_JSON_H
#define MACHTELD_ENGINE_JSON_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    EJ_NULL, EJ_FALSE, EJ_TRUE, EJ_INT, EJ_DOUBLE, EJ_STRING, EJ_ARRAY,
    EJ_OBJECT
} EjKind;

typedef struct Ej Ej;
struct Ej {
    EjKind kind;
    union {
        int64_t i;                    /* EJ_INT */
        double d;                     /* EJ_DOUBLE */
        struct {                      /* EJ_STRING: UTF-8, NUL-terminated */
            char *bytes;
            size_t len;
        } s;
        struct {                      /* EJ_ARRAY / EJ_OBJECT */
            Ej **items;               /* object: key,value,key,value,... */
            size_t count;             /* object: number of PAIRS */
        } a;
    } u;
};

/* Parse one JSON value from buf[0..len). Strict RFC 8259 plus the engine's
 * two bounds: nesting depth <= 32 and integer literals must fit int64.
 * Returns NULL on any violation and, when err is non-NULL, points *err at a
 * static description. The result is heap-owned; free with EjFree. */
Ej *EjParse(const char *buf, size_t len, const char **err);
void EjFree(Ej *v);

/* Object field lookup (linear; control messages are small). NULL if absent. */
Ej *EjGet(const Ej *obj, const char *key);

/* Append-only output buffer. */
typedef struct {
    char *bytes;
    size_t len;
    size_t cap;
    int oom;                          /* sticky allocation-failure flag */
} EjBuf;

void EjBufInit(EjBuf *b);
void EjBufFree(EjBuf *b);
void EjBufRaw(EjBuf *b, const char *s, size_t n);
void EjBufText(EjBuf *b, const char *s);           /* raw, NUL-terminated */
void EjBufInt(EjBuf *b, int64_t v);
void EjBufDouble(EjBuf *b, double v);              /* finite doubles only */
void EjBufString(EjBuf *b, const char *s, size_t n); /* quoted + escaped */

#endif /* MACHTELD_ENGINE_JSON_H */
