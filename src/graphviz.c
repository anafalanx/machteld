/* In-process dot layout using the static dot and xdot plugins. */
#include <limits.h>
#include <string.h>
#include <windows.h>
#include <tcl.h>
#include <graphviz/gvc.h>

extern gvplugin_library_t gvplugin_dot_layout_LTX_library;
extern gvplugin_library_t gvplugin_core_LTX_library;

static const lt_symlist_t plugins[] = {
    {"gvplugin_dot_layout_LTX_library", &gvplugin_dot_layout_LTX_library},
    {"gvplugin_core_LTX_library", &gvplugin_core_LTX_library},
    {NULL, NULL}
};

static void
Put(Tcl_Obj *dict, const char *key, Tcl_Obj *value)
{
    Tcl_DictObjPut(NULL, dict, Tcl_NewStringObj(key, -1), value);
}

static Tcl_Obj *
Pair(double x, double y)
{
    Tcl_Obj *items[] = {Tcl_NewDoubleObj(x), Tcl_NewDoubleObj(y)};
    return Tcl_NewListObj(2, items);
}

static void
PutDrawing(Tcl_Obj *result, void *object, const char *key, char *attribute)
{
    const char *value = agget(object, attribute);
    Put(result, key, Tcl_NewStringObj(value ? value : "", -1));
}

/* Return Graphviz points (72 per inch), with (0,0) at the canvas's top left. */
static Tcl_Obj *
CanvasPoint(boxf bounds, pointf point)
{
    return Pair(point.x - bounds.LL.x, bounds.UR.y - point.y);
}

static Tcl_Obj *
EdgeGeometry(Agedge_t *edge, boxf bounds)
{
    Tcl_Obj *result = Tcl_NewDictObj();
    Tcl_Obj *paths = Tcl_NewListObj(0, NULL);
    const char *id = agget(edge, "id");
    Put(result, "tail", Tcl_NewStringObj(agnameof(agtail(edge)), -1));
    Put(result, "head", Tcl_NewStringObj(agnameof(aghead(edge)), -1));
    PutDrawing(result, edge, "draw", "_draw_");
    PutDrawing(result, edge, "headDraw", "_hdraw_");
    PutDrawing(result, edge, "tailDraw", "_tdraw_");
    PutDrawing(result, edge, "labelDraw", "_ldraw_");
    if (id && *id) {
        Put(result, "id", Tcl_NewStringObj(id, -1));
    }
    const splines *route = ED_spl(edge);
    if (route) {
        for (size_t i = 0; i < route->size; ++i) {
            const bezier *curve = &route->list[i];
            Tcl_Obj *piece = Tcl_NewDictObj();
            Tcl_Obj *points = Tcl_NewListObj(0, NULL);
            for (size_t j = 0; j < curve->size; ++j) {
                Tcl_ListObjAppendElement(NULL, points, CanvasPoint(bounds, curve->list[j]));
            }
            Put(piece, "points", points);
            if (curve->sflag) {
                Put(piece, "startTip", CanvasPoint(bounds, curve->sp));
            }
            if (curve->eflag) {
                Put(piece, "endTip", CanvasPoint(bounds, curve->ep));
            }
            Tcl_ListObjAppendElement(NULL, paths, piece);
        }
    }
    Put(result, "splines", paths);
    return result;
}

static Tcl_Obj *
GraphGeometry(Agraph_t *graph)
{
    boxf bounds = GD_bb(graph);
    Tcl_Obj *result = Tcl_NewDictObj();
    Tcl_Obj *nodes = Tcl_NewDictObj();
    Tcl_Obj *edges = Tcl_NewListObj(0, NULL);
    Put(result, "size", Pair(bounds.UR.x - bounds.LL.x, bounds.UR.y - bounds.LL.y));
    Put(result, "origin", Pair(bounds.LL.x, bounds.UR.y));
    for (Agnode_t *node = agfstnode(graph); node; node = agnxtnode(graph, node)) {
        Tcl_Obj *card = Tcl_NewDictObj();
        Put(card, "center", CanvasPoint(bounds, ND_coord(node)));
        PutDrawing(card, node, "draw", "_draw_");
        PutDrawing(card, node, "labelDraw", "_ldraw_");
        Put(card, "size", Pair(ND_width(node) * POINTS_PER_INCH,
                               ND_height(node) * POINTS_PER_INCH));
        Put(nodes, agnameof(node), card);
        for (Agedge_t *edge = agfstout(graph, node); edge; edge = agnxtout(graph, edge)) {
            Tcl_ListObjAppendElement(NULL, edges, EdgeGeometry(edge, bounds));
        }
    }
    Put(result, "nodes", nodes);
    Put(result, "edges", edges);
    return result;
}

/* Graphviz's DOT parser and diagnostic callback use process-global state. */
static SRWLOCK layoutLock = SRWLOCK_INIT;
static Tcl_DString *diagnostic;

static int
captureMessage(char *message)
{
    if (diagnostic != NULL && Tcl_DStringLength(diagnostic) < 8192) {
        const size_t remaining = 8192u - (size_t)Tcl_DStringLength(diagnostic);
        Tcl_DStringAppend(diagnostic, message, (Tcl_Size)strnlen(message, remaining));
    }
    return 0;
}

static int
LayoutCmd(void *clientData, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
    static const char *const operations[] = {"layout", "xdot", NULL};
    int op = 0;
    (void)clientData;
    if (objc != 3 || Tcl_GetIndexFromObj(interp, objv[1], operations,
            "operation", TCL_EXACT, &op) != TCL_OK) {
        if (objc != 3) Tcl_WrongNumArgs(interp, 1, objv, "layout|xdot dotSource");
        Tcl_SetErrorCode(interp, "MACHTELD", "GRAPHVIZ", "usage", NULL);
        return TCL_ERROR;
    }
    Tcl_Size size = 0;
    const char *source = Tcl_GetStringFromObj(objv[2], &size);
    /* Tcl's string representation encodes NUL as C0 80. */
    if (size >= INT_MAX - 2 || memchr(source, 0, (size_t)size) || strstr(source, "\xc0\x80") != NULL) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("DOT input exceeds the parser limit or contains NUL", -1));
        Tcl_SetErrorCode(interp, "MACHTELD", "GRAPHVIZ", "input", NULL);
        return TCL_ERROR;
    }
    AcquireSRWLockExclusive(&layoutLock);
    Tcl_DString messages;
    Tcl_DStringInit(&messages);
    diagnostic = &messages;
    agusererrf previous = agseterrf(captureMessage);
    (void)agreseterrors();
    GVC_t *ctx = gvContextPlugins(plugins, 0);
    Agraph_t *graph = ctx ? agmemread(source) : NULL;
    const bool laidOut = graph && gvLayout(ctx, graph, "dot") == 0;
    char *bytes = NULL;
    size_t length = 0;
    const bool rendered = laidOut && gvRenderData(ctx, graph, "xdot", &bytes, &length) == 0 && bytes;
    const bool ok = rendered && length <= (size_t)TCL_SIZE_MAX && !agerrors();
    if (ok) {
        Tcl_SetObjResult(interp, op == 0 ? GraphGeometry(graph) : Tcl_NewStringObj(bytes, (Tcl_Size)length));
    } else {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(Tcl_DStringLength(&messages)
                ? Tcl_DStringValue(&messages) : "could not lay out DOT graph", -1));
        Tcl_SetErrorCode(interp, "MACHTELD", "GRAPHVIZ", graph ? "layout" : "input", NULL);
    }
    if (bytes) gvFreeRenderData(bytes);
    if (laidOut) gvFreeLayout(ctx, graph);
    if (graph) agclose(graph);
    if (ctx) (void)gvFreeContext(ctx);
    (void)agseterrf(previous);
    diagnostic = NULL;
    Tcl_DStringFree(&messages);
    ReleaseSRWLockExclusive(&layoutLock);
    return ok ? TCL_OK : TCL_ERROR;
}

int
Machteldgraphviz_Init(Tcl_Interp *interp)
{
    return Tcl_CreateObjCommand(interp, "::machteld::graphviz", LayoutCmd, NULL, NULL)
            ? TCL_OK : TCL_ERROR;
}
