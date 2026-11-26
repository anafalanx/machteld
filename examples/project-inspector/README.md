# Project Inspector

A small, read-only Machteld/Tk example: a directory table, selected-entry detail,
progress, bounded diagnostics, cancellation, and recovery after an error. It
inspects one directory, not a recursive project database, and never executes
commands found in the selected directory or changes its files.

The commands use the release gate's `out/machteld.exe`. After an incremental
build, use `out/dev/machteld.exe` in its place. The shared runtime launches both loose scripts and packaged archives.

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

- `model.tcl` interprets progress, rows and completion records. It uses the
  `machteld::job` Tcl package to own the child, drain its channels and cancel
  its timers. Both run headlessly. A repeated start while running returns 0.
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
  that failure and remains usable. The inspector uses the job package's
  defaults for both child limits.
- Generation checks reject stale callbacks. Cancel/close remove channel
  handlers, cancel timers, and release the child token. A failed observer stops
  the child and leaves an error in the model snapshot, without recursively
  calling the failed observer.

`launch.tcl` owns the entry roles. It appends `--worker` to the command prefix
from `app launch` for both scripts and archives. An archive worker uses the
version already open in the controller, even after an update. Each child
enters the same headless controller. Supervision is lifetime
ownership, not an authority sandbox: the trusted child retains the user's
filesystem permissions. Cancellation stops its work but is not a general
rollback mechanism; this particular worker is deliberately read-only.

## Run as an application archive

From the repository root, pack the example and run its headless inspection
against a local directory.

```powershell
.\out\machteld.exe pack .\examples\project-inspector\app.dict -o .\out\inspector.machteld
.\out\machteld.exe .\out\inspector.machteld --headless .\examples
```

The project dictionary selects the five application files. Move the archive and
start it with Machteld from any directory. The worker opens the same archive
generation even when a newer copy has been published at the original path.

`--headless directory ?inspect|slow|fail|noisy?` emits one UTF-8 JSON model
snapshot; exit 0 means done, 1 means a reported job failure, and 2 means invalid
arguments or an entry error. `--worker directory mode` is the internal JSON-lines
role, not the user-facing JSON snapshot. The headless and worker roles never initialize Tk.
The normal GUI accepts one optional directory; `-- directory` also handles a
directory argument that begins with `--`.

## Checks

```powershell
.\out\machteld.exe .\test\gui_model_test.tcl
.\out\machteld.exe .\test\application_corpus_test.tcl project-inspector
.\out\machteld.exe .\test\examples_package_test.tcl C:\dev\.z\r\msys2 .\.cache\deps\prefix
.\out\machteld.exe .\test\gui_widget_test.tcl
```

The model, corpus and example-packaging tests run headlessly. The model test covers
lifecycle, recovery, malformed protocols, bounds, and event-loop progress under
output. The corpus runs Inspector as loose Tcl, a relocated application archive
and a relocated standalone executable. It checks directory rows, worker identity,
bounded diagnostics and failure reporting. It also replaces the running archive
and checks which version the old controller and a fresh launch see. The packaging
test checks the unmodified example archive and its selected payload. It also
compiles a tiny extension using the explicitly named toolchain and Tcl prefix. The widget test creates
a visible, short-lived Tk window and temporarily uses the clipboard. It checks
real widget state/bindings, selection, keyboard focus, copying errors, cancellation,
resize, Tk scaling values 1.0/1.5/2.0, and close-during-work. These synthetic events
and Tk scaling checks supplement, but do not replace, human-style interaction or
Windows mixed-monitor/DPI/accessibility testing.

For manual acceptance, try Inspect, select a Unicode-named entry, resize the
window, start Slow demo and cancel it with Escape, run Fail demo and copy its
error, recover with Inspect, run Output demo while interacting with the window,
then close during another Slow demo. No child should remain owned afterwards.
