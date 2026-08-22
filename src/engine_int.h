/* engine_int.h -- the internal seam between the engine core (engine.c)
 * and the primitive palette (col.c). Not part of machteld.h: nothing here
 * exists for the Tcl hosts. col.c sees pools only through these accessors;
 * pool structures stay private to engine.c. Pools are READ-ONLY after
 * load (the contract's invariant), which is what makes concurrent column
 * access from shard states lawful without locks.
 */
#ifndef MACHTELD_ENGINE_INT_H
#define MACHTELD_ENGINE_INT_H

#include <stdint.h>
#include "lua.h"

/* Resolve one typed column of a live pool. Returns 1 and fills the outs
 * on success; 0 when the pool number is dead or the field is unknown.
 * *typeOut is 'i', 'f', or 's'; *dataOut points at the native array for
 * 'i'/'f' and is NULL for 's' (string columns are not col territory). */
int EnginePoolColumn(int poolNum, const char *field, char *typeOut,
                     const void **dataOut, int64_t *rowsOut);

/* Resolve the identity of a kernel-visible view table at stack index idx
 * in S: the monotone pool number and the [a,b) row range. Identity is
 * recorded invisibly at view creation (weak-keyed registry map), so a
 * kernel can neither forge nor collide with it. Returns 1 on success,
 * 0 when idx is not a view. */
int EngineViewIdentity(lua_State *S, int idx, int *poolNumOut,
                       int64_t *aOut, int64_t *bOut);

/* Is this pool number still alive? Views and selections may outlive
 * their pool as GC objects; every col resolution checks liveness so a
 * stale reference is a named refusal, never a stale pointer. */
int EnginePoolLive(int poolNum);

/* col.c entry point, called by the engine core - and only after the
 * core's own (plain-ISA) CPUID check passed: col.c is compiled -mavx2
 * and must not execute a single instruction before that gate. */
void MachteldCol_Open(lua_State *S);       /* installs the col library */

#endif /* MACHTELD_ENGINE_INT_H */
