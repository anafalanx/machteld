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
