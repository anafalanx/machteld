# Project Inspector

A small, read-only Machteld/Tk example: a directory table, selected-entry detail,
progress, bounded diagnostics, cancellation, and recovery after an error. It
inspects one directory, not a recursive project database, and never executes
commands found in the selected directory or changes its files.

Use the current unsigned candidate executable in `out/`, not the older signed
`dist/0.21` artifact. The candidate reports runtime version `0.22`; the manifest-
selected packaging and application metadata shown here are unavailable in the
older release. Build the candidate using the repository README before running
this example; candidate acceptance is still in progress.

From the repository root in PowerShell:

```powershell
.\out\machteld.exe .\examples\project-inspector\main.tcl 'C:\dev\_machteld'
```

The directory argument is optional. Inspect lists its entries; select a row to
see its full path. Slow demo takes approximately fifteen seconds before inspecting.
Fail demo produces an intentional, copyable error without changing files.
Output demo produces a burst of progress records and diagnostics. Cancel or
Escape stops the owned child; Inspect can then start again. Closing the window
also closes active work.

Ctrl+Enter starts inspection, Ctrl+L focuses the directory field, and Tab moves
between controls. The diagnostic text is selectable; Copy diagnostics copies
the error and retained log tail, independently of text selection.

## Pattern and limits

- `model.tcl` has no Tk dependency. Its `Job` owns one supervised child and all
  its channels/timers. A repeated start while running is rejected, never queued.
- `inspect.tcl` performs filesystem work in that child. stdout carries strict
  UTF-8 JSON lines; stderr carries diagnostics. The GUI drains both streams.
- `view.tcl` contains widgets and bindings. It coalesces model notifications into
  one render per 16 ms at most; rendering callbacks never call `update` or
  `vwait`. Browse deliberately opens Tk's modal directory picker.
- Each readable callback takes at most 8192 bytes from stdout or 8192 decoded
  characters from stderr. Protocol parsing yields after 32 records, rejects
  records over 65536 bytes, and retains at most 500 rows. Diagnostics retain only
  the last 8192 characters. Progress messages retain at most 1024 characters.
- The child has a 30-second lifetime deadline and a 128 MiB per-process committed-
  memory limit (`-mem 128M`), not a cap on the GUI's heap or total process-tree
  RSS. Directory enumeration itself occurs there and can fail on
  inaccessible, disappearing, very large, or slow directories. The GUI reports
  that failure and remains usable. These limits are application choices, not
  new runtime defaults.
- Generation checks reject stale callbacks. Cancel/close remove channel
  handlers, cancel timers, and release the child token. A failed observer stops
  the child and leaves an error in the model snapshot, without recursively
  calling the failed observer.

`launch.tcl` owns the entry roles. A source launch starts
`machteld.exe main.tcl --worker ...`; a wrapped launch starts its own executable
with `--worker ...`. The child never opens the view or recursively launches the
GUI. Both routes use the same controller and protocol. Supervision is lifetime
ownership, not an authority sandbox: the trusted child retains the user's
filesystem permissions. Cancellation stops its work but is not a general
rollback mechanism; this particular worker is deliberately read-only.

## Package deliberately

Use a new dedicated stage containing only the five listed payload files. The
manifest is inert data outside that stage; it selects those files and declares
the application's Windows identity independently from the Machteld runtime.
The README, test scripts, and manifest itself are not executable payloads.

```powershell
$stage = New-Item -ItemType Directory .\out\inspector-stage -ErrorAction Stop
'main.tcl', 'launch.tcl', 'model.tcl', 'view.tcl', 'inspect.tcl' | ForEach-Object {
    Copy-Item (Join-Path .\examples\project-inspector $_) $stage.FullName
}
.\out\machteld.exe wrap $stage.FullName -o .\out\inspector.exe --gui --manifest .\examples\project-inspector\app.dict --plan
.\out\machteld.exe wrap $stage.FullName -o .\out\inspector.exe --gui --manifest .\examples\project-inspector\app.dict
```

Read the plan's file list and hashes before packaging. Choose a fresh stage name
if it already exists; do not blindly delete or wrap the whole repository. Use
`--console` instead for a console-subsystem executable. Reference documentation
is omitted by default; explicitly add `--with-docs` to both commands if wanted.
The executable is the complete Inspector deployment: no adjacent worker scripts
or DLLs are required. Application metadata is not an Authenticode signature.

For automation without opening any window:

```powershell
.\out\machteld.exe .\examples\project-inspector\main.tcl --headless 'C:\dev\_machteld'
.\out\inspector.exe --headless 'C:\dev\_machteld' noisy 2>&1 | Out-String
```

The pipe explicitly captures output and makes PowerShell wait for the GUI-
subsystem executable; do not rely on an unredirected GUI launch to display its
stdout/stderr. A console-subsystem build can be invoked directly. In either
case the application role itself opens no window.

`--headless directory ?inspect|slow|fail|noisy?` emits one UTF-8 JSON model
snapshot; exit 0 means done, 1 means a reported job failure, and 2 means invalid
arguments or an entry error. `--worker directory mode` is the internal JSON-lines
role, not the user-facing JSON snapshot. A GUI basekit creates Tk's initial root
before application dispatch; non-UI roles destroy it before processing events.
The normal GUI accepts one optional directory; `-- directory` also handles a
directory argument that begins with `--`.

## Checks

```powershell
.\out\machteld.exe .\test\gui_model_test.tcl
.\out\machteld.exe .\test\examples_package_test.tcl C:\dev\.z\r\msys2 .\.cache\deps\prefix
.\out\machteld.exe .\test\gui_widget_test.tcl
```

The model and example-packaging tests open no windows. The model test covers
lifecycle, recovery, malformed protocols, bounds, and event-loop progress under
output. The packaging test builds both console/GUI forms, exercises actual
worker routing from unrelated directories, and checks selected payloads; its
second example compiles a tiny extension using the explicitly named toolchain
and Tcl prefix. The widget test creates
a visible, short-lived Tk window and temporarily uses the clipboard. It checks
real widget state/bindings, selection, keyboard focus, copying errors, cancellation,
resize, Tk scaling values 1.0/1.5/2.0, and close-during-work. These synthetic events
and Tk scaling checks supplement, but do not replace, human-style interaction or
Windows mixed-monitor/DPI/accessibility testing.

For manual acceptance, try Inspect, select a Unicode-named entry, resize the
window, start Slow demo and cancel it with Escape, run Fail demo and copy its
error, recover with Inspect, run Output demo while interacting with the window,
then close during another Slow demo. No child should remain owned afterwards.
