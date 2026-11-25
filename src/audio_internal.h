#ifndef MACHTELD_AUDIO_INTERNAL_H
#define MACHTELD_AUDIO_INTERNAL_H
#include "machteld.h"
#include "media/rae_common.h"

int audio_error(Tcl_Interp *interp, const char *code, const char *message);
int audio_runtime_error(Tcl_Interp *interp, rae_err code);
int audio_handle(Tcl_Interp *interp, const char *type, Tcl_ObjCmdProc *proc,
                 void *data, Tcl_CmdDeleteProc *destroy, Tcl_Command *command);
void audio_put(Tcl_Obj *dict, const char *key, Tcl_Obj *value);
int audio_output(Tcl_Interp *interp, Tcl_Obj *rate, Tcl_Obj *channels);
int audio_playlist(Tcl_Interp *interp, Tcl_Obj *base, Tcl_Obj *bytes);
int audio_demux(Tcl_Interp *interp, Tcl_Obj *bytes);
#endif
