#ifndef MACHTELD_DESKTOP_DROP_H
#define MACHTELD_DESKTOP_DROP_H
#include "tcl.h"

int desktop_drop(Tcl_Interp *, Tcl_HashTable *, Tcl_Obj *widget, Tcl_Obj *prefix);
void desktop_drops_free(Tcl_HashTable *);
#endif
