# Order relationships

Run `machteld.exe examples/graphviz-table/main.tcl`. Click an entry to select
its table. The application draws two named table ports, colored cells, text,
edges and arrowheads from the runtime's Graphviz output.

`view.tcl` converts xdot's coordinates and byte-counted strings into Tk canvas
items. It retains the DOT node name as a canvas tag so a click can identify the
node after layout.

Create an application archive and run it with the release candidate.

```powershell
.\out\machteld.exe pack .\examples\graphviz-table\app.dict -o .\out\graphviz-table.machteld
.\out\machteld.exe .\out\graphviz-table.machteld
```

## Edit a research instant

The second example uses a Tcl/Tk entry and a typed X query. From the root
of a checkout containing `machteld.exe`, pack the project and create its
synthetic SQLite database. To run it elsewhere, copy `machteld.exe`,
`research.machteld`, and `notes.db` together.

```powershell
.\machteld.exe project pack examples/graphviz-table/research.dict research.machteld
.\machteld.exe research.machteld --create-sample notes.db
.\machteld.exe research.machteld notes.db
```

Enter a timestamp with `Z` or a numeric UTC offset, then press Enter or
Apply. At `2026-11-01T09:15:00Z`, two different sources report that Bay
07 is open. Click the occurrence connected to **Field inspection** to see
its identifier `007-B`, source reference **Card 12**, and validity interval.
Change the instant to `09:29:00Z` on the same date and the selection stays
on that occurrence. At `09:30:00Z` it expires, the selection clears, and
the next inspection appears. Each interval includes its start and excludes
its end. Applying an invalid timestamp leaves the last valid diagram in place.

The data file is independent of the executable and archive. Its source and
occurrence tables contain stable text IDs, source references and canonical
UTC bounds with nine fractional digits. The query binds the research instant
and joins the source metadata in one SQLite read. The diagram keys each
occurrence by its stored ID across layout changes.

The headless entry emits a Tcl dictionary containing the canonical instant,
visible occurrence IDs, and the selected observation and its source. An
absent occurrence produces an empty selection. From the repository, use
the source project driver or run the delivered archive.

```powershell
.\machteld.exe project run examples/graphviz-table/research.dict --headless notes.db 2026-11-01T09:15:00Z 007-B
.\machteld.exe research.machteld --headless notes.db 2026-11-01T09:30:00Z 007-B
```

Run `machteld.exe test/research_diagram_test.tcl -pack` for headless SQL,
Graphviz, canvas interaction and relocation checks. On an attended desktop,
`machteld.exe test/research_diagram_test.tcl --tk` exercises a real Tk
canvas click and selection across edits.

### A typed window

`typed-window.dict` opens the same observations in a window created entirely
by X. The canvas, detail label, Redraw button, grid layout, click handler and
window lifetime are in `typed-window.src`. The small Tcl renderer reuses the
original Graphviz layout and paint routines. It attaches the database's
occurrence key to every native item belonging to a node. Select the box or
its label to see the source, then press Redraw to restore the selection
against newly created items.

The window keeps its admitted occurrence list in a scoped `ref`. The click
and redraw callbacks capture the same reference and read the snapshot with
`ref_get`. Each event checks that the reference is live. The enclosing
`using` retains the rows through window cleanup and releases them on exit.
Use this pattern when several events need the same large, stable query result.

On a Windows development host, querying 384 occurrences and handling four
clicks took a median of 19 ms with the scoped snapshot and 11 ms in
handwritten Tcl using the same linear search. With the rows already loaded,
the four callbacks took 1.74 ms in X and 0.56 ms in Tcl. These 30 paired
trials timed the operation inside a running process and checked the full
ordered rows, label text, selection state and canvas commands off screen.

```powershell
.\machteld.exe project pack examples/graphviz-table/typed-window.dict observations.machteld
.\machteld.exe observations.machteld --lookup notes.db 2026-11-01T09:15:00Z 007-B
```

On an attended desktop, run `machteld.exe observations.machteld notes.db
2026-11-01T09:15:00Z` to open the window. The `--lookup` form above uses
the same typed provenance lookup without opening a display.
