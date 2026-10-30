# Explicit adjacent native extension

This deliberately small example demonstrates an application with an external
Windows x64 Tcl 9 extension. `examplemath.dll` provides one checked native command:
`examplemath::add signed32 signed32`. Its exact 64-bit result illustrates the
loading boundary, not a claim that ordinary arithmetic needs a native extension.

These commands target the current executable in `out/`, machteld 22 in
preparation, not the older signed `dist/0.21` artifact. Runtime version `22`
and its inventory and application-metadata packaging differ from that release.
Build it using the repository README first; acceptance of 22 is still in
progress.

The application loads an absolute DLL filename beside its executable. It does
not resolve dependencies, use `auto_path`, search the current directory or PATH
for this DLL, download packages, or extract code from zipfs. There is no plugin
manager. Treat the DLL as fully trusted native code with the user's permissions.
The operating system still resolves a DLL's own imports; this example uses Tcl
stubs and statically links the compiler support so no separate Tcl or GCC DLL
needs to be deployed. System Windows/UCRT libraries remain platform dependencies.

## Build a dedicated distribution

After the repository's documented dependency bootstrap, from its root:

```powershell
.\out\machteld.exe .\examples\external-extension\build.tcl .\out\extension-stage C:\dev\.z\r\msys2 .\.cache\deps\prefix
.\out\extension-stage\bundle\extension-example.exe 20 22 2>&1 | Out-String
```

Pass your resolved MSYS2 root and Tcl prefix explicitly if different. The script
requires GCC under `ucrt64/bin`, Tcl 9 headers under `include`, and the stubs
archive under `lib`; it neither bootstraps nor rebuilds Machteld. Compilation
uses warnings-as-errors and `USE_TCL_STUBS`. Append `--gui` to build a GUI-subsystem
host for a headless-launch demonstration: this application always destroys the
unmapped initial Tk root before doing any work and never opens a window.
The output pipe above makes PowerShell wait and capture stdout/stderr for either
subsystem; an unredirected GUI-subsystem launch should not be expected to print
to its parent's console.

The stage must not already exist. It contains `app/main.tcl` separately from
`bundle/`, the directory to deploy. `app.dict` explicitly selects only `main.tcl`
and provides application identity. Source code, the builder, and documentation
are not embedded. On failure the stage is left for diagnosis; choose a fresh
stage rather than overwriting a possibly valuable directory.

Ship the **entire** bundle, keeping these filenames and their relative location:

```text
bundle/
  extension-example.exe
  examplemath.dll
  LICENSE-examplemath.txt
  NOTICE-examplemath.txt
  ship.dict
```

`ship.dict` is inert UTF-8 Tcl dictionary data listing every deployment file
except itself, with byte sizes and SHA-256 hashes. The executable separately
carries `app-info.dict` for its embedded payload and runtime provenance. These
inventories detect accidental drift when checked; they are not signatures or a
trust mechanism. The example DLL's full Apache-2.0 license and attribution travel
beside it; the host's embedded licenses retain Tcl and other runtime notices.
The example builder omits the optional runtime reference corpus.

Run the bundle from any working directory. Removing or relocating its adjacent
DLL produces a clear error even if another `examplemath.dll` is in the working
directory. This is intentionally not a one-file application: decide and document
the full deployment set for each real extension, including its transitive DLLs,
architecture, ABI, licenses, and update/signing policy.

## Headless acceptance

```powershell
.\out\machteld.exe .\test\examples_package_test.tcl C:\dev\.z\r\msys2 .\.cache\deps\prefix
```

This checks the Inspector source/console/GUI worker routes and both extension
host forms without opening windows. It verifies exact embedded and adjacent
inventories, hashes, license content, Unicode/space deployment paths, execution
from an unrelated directory, native argument bounds, and missing-DLL behavior.
Application PE identity and documentation opt-in combinations are also covered
by the wrapper's dedicated acceptance suites.
