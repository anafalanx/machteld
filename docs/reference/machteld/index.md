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

This tree reports runtime version 30, in preparation and not yet released.
Match these pages to the executable's corpus and artifact identity, not merely
its package version: builds can change without a new version number.
Conceptual guides state design intent and history separately from the
implemented command pages.

Every command lives in `::machteld`. At top level, use the short names below
and the qualified name `::machteld::clipboard`. Tk supplies the global
`clipboard` command when loaded. Nested namespaces can use fully qualified
names or add `::machteld::palette` to their namespace path for the short names.

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
- Filesystem and machine state: `dirs`, `links`, `canon`, `watch`, `mtps`, `lock`, and `publish`.
- Data and network: `http`, `json`, `hash`, and `store`.
- Tool construction: `cli`, `log`, `worker`, `pool`, and `pmap`.
- Runtime and distribution: `app`, `version`, `manifest`, `docs` and `help`.

For text-file bytes, `package require machteld::encoding 1.0` exposes
`::machteld::encoding::detect $bytes`. Supply a bytearray, such as the
result of `read` on a binary channel. The dictionary contains `status`,
`encoding`, `confidence` and `samplebytes`. A `match` supplies an ICU
encoding label and its estimate from 1 to 100. Empty or printable ASCII
samples can have many source encodings and return `nomatch`. Other samples
for which the detector finds no match also return `nomatch`. When Windows
does not provide the required ICU entry points, detection returns
`unavailable`. Both results carry an empty label and zero confidence.
The detector examines up to the first 1 MiB and preserves the supplied bytes.
Applications choose their confidence threshold and Tcl decoder.

### Windows network diagnostics

`package require machteld::network 1.0` loads these commands in a trusted interpreter.

- `::machteld::network::wifi` returns a dictionary containing `status`
  (`ok`, `restricted`, or `unavailable`), `winerror`, `addresserror` and
  `adapters`. Each adapter reports its `guid`, `description`, `state`,
  `details`, `winerror` and preferred `ipv4` address list. When Windows
  IP Helper matches the interface it also supplies the friendly `name`.
  An `addresserror` explains a failure to enumerate IP addresses.
  With `details ok`, `ssid` contains the original network-name bytes,
  `quality` is a percentage, and `rxkbps` and `txkbps` are the negotiated
  receive and transmit rates in kilobits per second. Other detail states
  are `disconnected`, `restricted` and `unavailable`. A location permission
  restriction leaves the adapter identity available and omits the private
  measurements. An empty adapter list with `status ok` means that Windows
  enumerated zero interfaces.
- `::machteld::network::ping sourceIPv4 destinationIPv4 ?timeoutMs?`
  sends one IPv4 echo using the supplied preferred address of an active
  local interface. Both arguments are numeric IPv4 literals. The deadline
  defaults to 1,000 ms and accepts 1 through 60,000 ms. A result with
  `status ok` supplies `rttms` and `winerror 0`. A `timeout` or `error`
  supplies the Windows/IP status in `winerror`. The call waits for its
  result. Use a worker for Tk applications that need to remain responsive
  during the wait.

### UDP sockets

`::machteld::network::udp open address port` creates a nonblocking,
interpreter-owned socket and returns its command. Use `127.0.0.1` or
`::1` for loopback. Use port `0` to let Windows choose an available port.
Addresses are numeric IPv4 or IPv6 literals. An IPv6 link-local address may
include a numeric scope, for example `fe80::1%12`.

- `$socket local` returns the bound `address` and `port`.
- `$socket send address port value` sends one datagram to an address
  of the same family and returns its byte count. Bytearrays retain every
  byte. Other values are encoded as UTF-8. An empty value sends an empty
  datagram. Maximum payloads are 65,507 bytes for IPv4 and 65,527 for IPv6.
- `$socket receive` takes one complete datagram from the kernel queue
  and returns `address`, `port` and a `bytes` bytearray. An empty result
  means the queue is empty. An empty *datagram* still has a sender and a
  `bytes` field. UDP preserves datagram boundaries. Delivery and network
  arrival order depend on the network.
- `$socket readable commandPrefix` calls the prefix with the socket
  command as its final argument when a datagram is ready. It runs through
  the owning Tcl event loop. Receive at least one datagram in the handler
  to rearm notification on further queued data. The no-argument form
  returns the installed prefix. Supply `{}` to cancel pending notifications.
  A handler error disables its registration and goes through Tcl's
  background error handling.
- `$socket close` cancels pending callbacks and releases the socket.
  Deleting its command or interpreter does the same. A callback can close
  its own socket. Windows errors raise `MACHTELD UDP oserror number`.

```tcl
package require machteld::network 1.0
set socket [::machteld::network::udp open 127.0.0.1 0]
$socket readable [list apply {{s} {
    set packet [$s receive]
    puts [list [dict get $packet address] [dict get $packet port] [dict get $packet bytes]]
    $s close
    set ::done 1
}}]
$socket send 127.0.0.1 [dict get [$socket local] port] [binary decode hex 00ff]
vwait ::done
```

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
