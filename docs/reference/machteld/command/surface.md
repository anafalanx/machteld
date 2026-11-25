---
id: machteld/command/surface
type: command
title: surface
summary: Draw Tcl geometry, sprites and shaders into a Direct2D or Direct3D 11 Tk child window.
commands: surface, surface d2d, surface d3d
---

# surface

## Synopsis

```tcl
surface d2d path ?-width pixels? ?-height pixels? ?-driver auto|hardware|warp? ?-scale factor?
surface d3d path ?-width pixels? ?-height pixels? ?-driver auto|hardware|warp?
```

## Arguments and options

Supply an available Tk child path. The default size request is 320 by 240
Tk client pixels. Pack, grid or place the widget and bind ordinary Tk events.
The `auto` driver tries hardware first and falls back to Windows WARP.
The other two settings require the specified driver.

## Results

The result is the widget command. `$path draw clearColor geometry` renders
and presents a frame synchronously. `$path pixels {{x y} ...}` renders it
again and samples the back buffer before presentation. Coordinates are
integer back-buffer pixels from the top left. Results are ordered `#rrggbbaa`
strings containing the stored channel bytes. A Direct2D target stores
premultiplied colors. Opaque output gives identical stored and straight RGB.

`$path info` returns `backend`, `driver`, DXGI `adapter` name, `software`
(the adapter's software flag), `featureLevel` (hexadecimal),
drawable `width` and `height`, Windows `dpi`, configured `scale` and device
`generation`. The driver is `pending` until the first draw.

## Errors

Native failures use `MACHTELD SURFACE` followed by `device`, `format`,
`limit`, `shader` or `size`. Compilation errors include the shader stage and
compiler diagnostics. A rejected drawing list leaves the previous scene available.

## Lifetime and timeouts

Tk redraws the last scene after exposure and size changes. Change the size
request with `$path configure -width w -height h`. The runtime retries a
lost graphics device or Direct2D target once using the retained scene, image
bytes and shader bytecode. `$path recreate` exercises this recovery path
by explicitly discarding and recreating graphics resources. Destroying the
window or deleting its command releases them. Schedule animation with Tk's
`after` and cancel application timers when the widget closes.

## Examples

```tcl
set p [surface d2d .drawing -width 200 -height 120]
pack $p
update idletasks
$p draw #102030 {{ellipse 40 40 30 30 #ffeeaa} {line 40 40 40 18 3 #402010}}
set pixel [$p pixels {{0 0}}]
```

## Constraints

Each side supports up to 8192 back-buffer pixels and a surface supports up to
16,777,216 pixels, 196,608 drawing elements and 65,536 samples per read.
Readback synchronizes with the device. Use it for occasional inspection.
Both rendering paths require a Windows desktop capable of creating a
Direct3D 11 device at feature level 10.0 or later.

## Subcommands

<a id="d2d"></a>
### d2d

#### Synopsis

`surface d2d path ?-width pixels? ?-height pixels? ?-driver mode? ?-scale n?`

#### Arguments and options

The geometry list accepts `{rect x y width height color}`,
`{ellipse centerX centerY radiusX radiusY color}`,
`{line x1 y1 x2 y2 thickness color}` and `{sprite name x y width height}`.
Colors are `#rrggbb` or `#rrggbbaa`. Coordinates and line widths are
device-independent units, scaled by the window DPI divided by 96 and by
`-scale`. The application scale defaults to 1 and accepts 0.125 through 8.
Windows may apply further scaling when composing a DPI-virtualized Tk window
on a display. The reported DPI belongs to the Tk child window.

#### Results

`$path image name width height rgbaBytes` installs or replaces a named image.
Supply row-major straight-alpha RGBA, four bytes per pixel, top row first.
The runtime premultiplies once, caches the image and draws sprites with
nearest-neighbor sampling. Geometry is drawn in list order.

#### Errors

A missing sprite name, malformed color or negative size produces `format`.
Oversize images or sprite storage raise `size` or `limit`.

#### Lifetime and timeouts

An image remains associated with its surface until replaced or the widget
closes. `$path configure -scale 2` doubles logical drawing dimensions.

#### Examples

```tcl
set p [surface d2d .game]
pack $p
$p image marker 1 1 [binary decode hex ff0000ff]
$p draw #000000 {{sprite marker 10 12 16 16}}
```

#### Constraints

Each widget accepts 4096 named sprites with an aggregate limit of 64 MiB.
Each image side is limited to 4096 pixels.

#### See also

`machteld/command/surface#d3d`.

<a id="d3d"></a>
### d3d

#### Synopsis

`surface d3d path ?-width pixels? ?-height pixels? ?-driver mode?`

#### Arguments and options

Install Tcl-provided HLSL with `$path shader vertexSource pixelSource`.
Each stage has an entry point named `main`, compiled for shader model 4.
Vertex input contains `float3 POSITION` and `float4 COLOR`. Emit
`SV_POSITION` in clip space and a color from the pixel shader at `SV_TARGET`.
The draw geometry is a triangle list of `{x y z color}` vertices with no
face culling. Color channels enter the shader as floats between zero and one.

#### Results

`$path draw` presents the application shader's color output.
Read several pixels with a single `$path pixels` call.

#### Errors

Malformed HLSL raises `shader`. An invalid replacement leaves a previously
installed shader program in place. A nonempty triangle list requires a program.

#### Lifetime and timeouts

Shaders compile on the calling thread. Install them before the animation loop.
The widget retains the compiled programs across size changes and device recreation.

#### Examples

```tcl
set p [surface d3d .tri]
pack $p
$p shader {
    struct V { float4 pos : SV_POSITION; float4 color : COLOR; };
    V main(float3 pos : POSITION, float4 color : COLOR) {
        V v; v.pos = float4(pos, 1); v.color = color; return v;
    }
} {
    float4 main(float4 pos : SV_POSITION, float4 color : COLOR) : SV_TARGET {
        return color;
    }
}
$p draw #102030 {{0 0.8 0 #ff0000} {-0.8 -0.8 0 #00ff00} {0.8 -0.8 0 #0000ff}}
```

#### Constraints

Each shader source accepts up to 256 KiB. The interface exposes a BGRA8
color target and a triangle vertex stream. Window resize updates the viewport.

#### See also

`machteld/command/surface#d2d`.

## See also

`machteld/command/surface#d2d` and `machteld/command/surface#d3d`.
