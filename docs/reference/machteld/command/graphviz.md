---
id: machteld/command/graphviz
type: command
title: graphviz
summary: Lay out a DOT graph and return geometry or xdot drawing instructions.
commands: graphviz, graphviz layout, graphviz xdot
---

# graphviz

## Synopsis

```tcl
graphviz layout dotSource
graphviz xdot dotSource
```

## Arguments and options

Pass a DOT graph as one Tcl string. The runtime uses the static Graphviz
`dot` engine and Expat for HTML-like labels. See the named-port table in
`examples/graphviz-table`.

## Results

`layout` returns a dict describing nodes and edge paths. `xdot` returns the
Graphviz drawing as a DOT document with xdot attributes.

## Errors

The structured error codes are `MACHTELD GRAPHVIZ usage`, `input` and `layout`.
DOT diagnostics are returned to the Tcl caller.

## Lifetime and timeouts

Calls complete synchronously and return Tcl values. Each call releases its
graph and layout context before returning.

## Examples

```tcl
set diagram [graphviz layout {digraph {a -> b}}]
set center [dict get $diagram nodes a center]
```

## Constraints

`dot` supports orthogonal routing and named HTML table ports. For a layout
that depends on the exact named cell attachment, use ordinary spline routing.
Graphviz's orthogonal router can choose the same attachment for different
ports. Label extents use Graphviz's built-in font estimates.

The runtime contains Graphviz 16.1.2 and Expat 2.8.1. The source archive
hashes and static build recipe are in Machteld's `tools/dependencies.lock.json`
and `tools/graphviz-build.tcl`. The bundled notices are in `licenses/`.
[Graphviz source](https://gitlab.com/api/v4/projects/4207231/packages/generic/graphviz-releases/16.1.2/graphviz-16.1.2.tar.xz) · [Expat source](https://github.com/libexpat/libexpat/releases/download/R_2_8_1/expat-2.8.1.tar.xz)

## Subcommands

<a id="layout"></a>
### layout

#### Synopsis

`graphviz layout dotSource`

#### Arguments and options

Supply one graph in DOT syntax, including any attributes used by the layout.

#### Results

The dict has `size` (width and height), `origin` (the original left and top
in Graphviz points), a `nodes` dict keyed by DOT name, and an `edges` list.
Node records contain `center`, `size`, `draw` and `labelDraw`. Edge records
contain `tail`, `head`, optional explicit `id`, `splines`, `draw`, `labelDraw`,
`headDraw` and `tailDraw`. Each spline gives its cubic `points` and optional
`startTip` and `endTip`. Node centers and routes use a top-left origin.
The drawing strings use xdot's original coordinate system. For an xdot
point `x y` and origin `left top`, use `x-left` and `top-y` on a canvas.

#### Errors

`input` covers invalid DOT and embedded NUL. `layout` reports a layout or
drawing failure. `usage` covers argument errors.

#### Lifetime and timeouts

The returned dict can be retained and used by Tcl or Tk after the call.

#### Examples

```tcl
set g [graphviz layout {digraph {a -> b [id=next]}}]
set route [dict get [lindex [dict get $g edges] 0] splines]
```

#### Constraints

Geometry is measured in points (72 per inch). Parallel edges each have
a separate record. Their optional IDs come from the DOT input.

#### See also

`machteld/command/graphviz#xdot`.

<a id="xdot"></a>
### xdot

#### Synopsis

`graphviz xdot dotSource`

#### Arguments and options

Pass one DOT graph, including HTML-like labels or named ports as needed.

#### Results

Returns the complete xdot document, including positioned drawing attributes
for the graph, clusters, nodes and edges.

#### Errors

The same `input`, `layout` and `usage` codes apply as for `layout`.

#### Lifetime and timeouts

The string remains valid after the native renderer releases the graph.

#### Examples

```tcl
set drawing [graphviz xdot {digraph {a [label="Start"]; a -> b}}]
```

#### Constraints

The result is data in the xdot format. Text lengths within drawing operations
count UTF-8 bytes. The renderer registers the static DOT-family output plugin.

#### See also

`machteld/command/graphviz#layout`.

## See also

`machteld/command/graphviz#layout`, `machteld/command/graphviz#xdot`.
