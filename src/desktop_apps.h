#ifndef MACHTELD_DESKTOP_APPS_H
#define MACHTELD_DESKTOP_APPS_H
#include "tcl.h"

typedef struct desktop_catalog desktop_catalog;
void desktop_catalog_free(desktop_catalog *catalog);
int desktop_applications(Tcl_Interp *interp, const char *issuer, desktop_catalog **catalog);
int desktop_launch_app(Tcl_Interp *interp, desktop_catalog *catalog, Tcl_Obj *token);
int desktop_app_icon(Tcl_Interp *interp, desktop_catalog *catalog, Tcl_Obj *token,
                     Tcl_Obj *photo, Tcl_Obj *size);
#endif
