# An adjacent Tcl extension

This example builds a Windows x64 Tcl 9 stubs DLL and calls
`examplemath::add signed32 signed32` from a packaged Tcl application. The
installer or user can move the complete folder to another directory.

From the repository root in PowerShell, use the executable produced by the
release gate or substitute `out/dev/machteld.exe` for an incremental build.

```powershell
.\out\machteld.exe .\examples\external-extension\build.tcl .\out\extension-stage C:\dev\.z\r\msys2 .\.cache\deps\prefix
.\out\extension-stage\bundle\machteld.exe .\out\extension-stage\bundle\extension-example.machteld 20 22
```

The second command prints `42`. Pass the actual MSYS2 root and Tcl prefix on
the build machine. The builder requires an absent stage directory, GCC, the
Tcl headers and the Tcl stubs archive. It compiles the DLL with
`USE_TCL_STUBS` and copies the runtime byte for byte.

Distribute `bundle/` as a unit. It contains `machteld.exe`,
`extension-example.machteld`, `examplemath.dll`, `LICENSE-examplemath.txt`,
`NOTICE-examplemath.txt` and `ship.dict`. The last file records every other
file's length and SHA-256. Within the archive, the project inventory selects
only `main.tcl`. At launch the application locates the DLL beside its archive
using `$argv0` and loads its absolute path. A user may also point a separately
installed Machteld at the archive in this folder.

A real extension can require other DLLs. Include their notices and test the
complete folder on a machine with the intended Windows configuration. A loaded
extension has the process's permissions. [External libraries](../../docs/extensions.md)
