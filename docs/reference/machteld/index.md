---
id: machteld/index
type: index
title: Machteld reference
summary: Entry point for the complete, version-matched Machteld command reference.
commands:
---

# Machteld reference

This is the authoritative command-by-command reference for the Machteld runtime
in this executable. Each command page states its complete public syntax, values,
errors, resource lifetime, constraints, and examples. Use `manifest` for a
structured inventory of the running API and the documentation interface for
exact lookup and search.

This tree builds Machteld 0.50-dev with Tcl package API 30.
Match these pages to the executable's corpus and artifact identity, not merely
its package version: builds can change without a new version number.
Conceptual guides state design intent and history separately from the
implemented command pages.

Every command lives in `::machteld`. At top level, use the short names below
and the qualified name `::machteld::clipboard`. Tk supplies the global
`clipboard` command when loaded. Nested namespaces can use fully qualified
names or add `::machteld::palette` to their namespace path for the short names.

## Interpreter scope

The host initializes the main interpreter for each entry script or archive.
A supervised worker launched through `app launch` receives its own initialized
main interpreter, including the palette and the `machteld` and `sqlite3`
package registrations.

Plain `interp create` creates a Tcl child interpreter in the same process.
It starts without the full palette, and `package require machteld` and
`package require sqlite3` fail in a fresh child with its default package
paths. Some optional packages are independently loadable there, including
`cffi`, `machteld::files`, `machteld::network` and `machteld::encoding`
in an ordinary trusted child. Choose a supervised worker for code that
expects the full application runtime, and open its database connection there.

## Command groups

- Process control: `run`, `child`, `wait`, `scope`, and `detach`.
- Interactive processes: `pty`.
- Windows desktop: `child present` shows the state of a supervised application
  window. `desktop windows` lists open application windows and `desktop activate`
  requests foreground for a selected window. `desktop open` dispatches a local
  document to its associated viewer. `desktop apps` lists Start-menu shortcuts
  and Store applications. `desktop launch` opens a selected application, and
  `desktop icon` copies its icon into a Tk photo. `::machteld::clipboard owned` checks whether
  this process owns the clipboard. Use `browser` to launch or resume an
  app-owned Edge or Chromium tab, navigate and wait for its document to load.
  `desktop drop` delivers Explorer file lists to a callback on a selected Tk widget.
- Filesystem and machine state: `dirs`, `links`, `canon`, `watch`, `mtps`, `lock`, and `publish`.
- Data and network: `http`, `json`, `hash`, and `store`.
- Tool construction: `cli`, `log`, `worker`, `pool`, and `pmap`.
- Runtime and distribution: `app`, `wrap`, `version`, `manifest`, `docs` and `help`.

## Find a runtime capability

Use `docs list -scope machteld -type command` for the palette and `docs list -scope machteld -type package` for optional packages. `docs get` accepts the exact IDs below. Plain Tcl and Tk commands, widgets and C APIs have their own product scopes.

| Capability | Reference ID |
| --- | --- |
| Browser profiles, navigation and readiness | `machteld/command/browser` |
| Initial visibility of supervised children | `machteld/command/child#start` |
| Windows on the desktop and foreground activation | `machteld/command/desktop#windows`, `machteld/command/desktop#activate` |
| Installed applications, shortcuts, icons and launch targets | `machteld/command/desktop#apps`, `machteld/command/desktop#icon`, `machteld/command/desktop#launch` |
| Explorer file drops on a Tk widget | `machteld/command/desktop#drop` |
| Opening local documents in their associated application | `machteld/command/desktop#open` |
| Typed numbered SQLite parameters, foreign-key and defensive settings, FTS5 trigram search | `machteld/package/sqlite3` |
| Create-only verified database backups | `machteld/package/sqlite` |
| Confirmed file replacement and flush outcomes | `machteld/command/publish` |
| Bulk directory entries and local-only cloud file reads | `machteld/package/files` |
| Text encoding and confidence | `machteld/package/encoding` |
| Seed-zero XXH3-64 checksums | `machteld/command/hash` |
| Streaming HTTP, bounded reads and cancellation | `machteld/command/http#stream` |
| Loopback HTTP server | `machteld/package/httpd` |
| Wi-Fi details, source-address ping, UDP sockets and authenticated network time | `machteld/package/network` |
| PCM output, MP3, AAC and HE-AAC decoding | `machteld/command/audio` |
| Live HLS audio playlists and MPEG-TS | `machteld/command/hls`, `machteld/command/audio#demux` |
| Direct2D sprites and Direct3D 11 shaders in Tk | `machteld/command/surface` |

Other runtime facilities include `machteld/package/job` for supervised background jobs, `machteld/package/cffi` for synchronous Windows DLL calls, `machteld/command/graphviz` for layout and rendering, `machteld/command/app` for per-user data paths and application relaunch, and `machteld/application/host` for entry scripts and application archives.

### Windows network diagnostics

Load `machteld::network` to enumerate wireless adapters with `::machteld::network::wifi`.
Use `::machteld::network::ping sourceIPv4 destinationIPv4` to select the sending
adapter by its preferred address. `docs get machteld/package/network` describes
the result fields, privacy restrictions and timeout outcomes.

### UDP sockets

`::machteld::network::udp open address port` returns a datagram socket.
Use its `readable` callback to receive data in the Tcl event loop and `close`
to release it. Retrieve `machteld/package/network` for the socket methods,
payload limits and a binary loopback example.

### Authenticated network time

`::machteld::network::nts sample hostname` returns an authenticated time
sample. The `start` form provides a cancellable request for event-driven
applications. `machteld/package/network` documents result fields, certificate
validation and errors.

The complete Tcl 9 and Tk 9 references are separate scopes in the embedded
reference pack. Search for an exact Tcl command such as `tcl/command/dict` when
the language itself, rather than the Machteld palette, is the subject. Upstream
`application` pages describe upstream `tclsh`/`wish`; Machteld entry and host
routes are defined only by this Machteld reference.

The shared runtime carries the reference. Programs can use it from either a
direct entry file or an archive.

Machteld executes trusted Tcl and native extensions with the user's permissions.
Entry declarations, supervised lifetimes, resource limits, and archive inventories
are not sandboxing or publisher authentication. Retrieve
`machteld/guide/contract` for cross-command rules and
`machteld/guide/execution-model` for GUI-safe composition of blocking and evented
operations.
