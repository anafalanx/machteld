# Catalogue Lookup

Run this from the repository root in PowerShell using the release gate's
`out/machteld.exe`. After an incremental build, use `out/dev/machteld.exe`.

```powershell
.\out\machteld.exe .\examples\sqlite-lookup\main.tcl
```

The example creates a temporary SQLite database of 125,000 synthetic items in
a worker. Choose a category, search, and use Next to move through the results.
A search opens its own read-only connection and uses the last displayed item ID
to fetch the next page. The worker reads one extra row to tell the window
whether to enable Next. Tk displays at most 50 items and inserts them in small
batches so input and repaint events can run during delivery.

To run the same window and its workers from an application archive, run these commands.

```powershell
.\out\machteld.exe pack .\examples\sqlite-lookup -o .\out\catalogue.machteld
.\out\machteld.exe .\out\catalogue.machteld
```

To keep a catalogue and run the wrapped example from another directory:

```powershell
.\out\machteld.exe .\examples\sqlite-lookup\main.tcl --create-demo .\catalogue.db
.\out\machteld.exe wrap .\examples\sqlite-lookup -o .\catalogue.exe --manifest .\examples\sqlite-lookup\app.dict --gui
.\catalogue.exe .\catalogue.db
```

The packaged executable relaunches itself in a worker role. Cancel stops the
current search. Starting a new search discards pending rows from the previous
request. Closing the window releases the child and its SQLite connection.
