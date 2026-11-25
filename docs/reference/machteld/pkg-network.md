---
id: machteld/package/network
type: package
title: Windows network diagnostics, datagrams and authenticated time
summary: Inspect Wi-Fi adapters, send source-bound ICMP probes, exchange UDP datagrams and obtain authenticated NTS time samples.
commands: machteld::network, ::machteld::network::wifi, ::machteld::network::ping, ::machteld::network::udp, ::machteld::network::nts, network wifi, network ping, udp open, nts sample, nts start, machteld::network::wifi, machteld::network::ping, machteld::network::udp, machteld::network::nts
---

# Windows network diagnostics, datagrams and authenticated time

## Wi-Fi and source-bound ping

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

## UDP sockets

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

## Authenticated network time

`::machteld::network::nts sample hostname ?-port port? ?-timeout ms?
?-trustroot derBytes?` obtains one authenticated Network Time Security
sample. The host name selects the TLS key-exchange server. Port defaults
to 4460. The deadline covers resolution, TLS, key negotiation and the UDP
exchange. It defaults to 5,000 ms and accepts 1 through 120,000 ms.

The result contains `unixms`, the estimated UTC Unix time in milliseconds
at receipt, `rttms`, the measured UDP round-trip time, and the authenticated
server's `stratum`. Machteld converts the server's NTP time to the era
nearest the local date. That calculation assumes the local clock is within
68 years of the server. The application decides how to use the sample and
when to request another one.

Windows Schannel verifies the server's certificate and name. An optional
`-trustroot` supplies one DER-encoded CA certificate as the exclusive root
for that request. It is useful for private time services. Peer checks still
include the certificate's validity, server authentication usage and name.
NTS requires TLS 1.3, ALPN `ntske/1`, NTPv4 and AES-SIV-CMAC-256. A sample
requires a response authenticated under the negotiated server key, bound to
the request identifier and origin timestamp, from a synchronized server.
Each request performs fresh key establishment and releases its session keys
and cookies when it finishes. The client accepts up to 16 KiB of key-exchange
records, 2 KiB per cookie and an 8 KiB UDP reply. There are no automatic retries.

`::machteld::network::nts start hostname ?options?` starts the same
exchange asynchronously and returns a request command. `$request status`
returns `pending`, `ok`, `error`, `timeout` or `cancelled`. `$request result`
retrieves the result immediately. `$request wait` waits for a terminal state,
bounded by the original deadline. `$request cancel` cancels a pending request.
`$request close` releases the command, cancelling unfinished work. Renaming
the command to the empty string or deleting its interpreter also releases it.
Tk programs can poll `status` with `after` while their window handles input.

On timeout, cancellation or a premature result lookup, the error code is
`MACHTELD NTS timeout`, `MACHTELD NTS cancelled` or `MACHTELD NTS pending`.
Transport, certificate, protocol and authentication failures report
`MACHTELD NTS failed stage code`. A successful sample contains no key or
cookie material. The public API only reads the system clock.

## Diagnostic errors and example

`MACHTELD NETWORK badvalue` identifies invalid ping input. Wi-Fi permission failures and network timeouts are reported through the documented status fields. UDP argument errors can raise `MACHTELD UDP badvalue`. A socket and an NTS request belong to their creating interpreter.

```tcl
package require machteld::network
set survey [::machteld::network::wifi]
foreach adapter [dict get $survey adapters] {
    puts [list [dict get $adapter guid] [dict get $adapter details] [dict get $adapter ipv4]]
}
```
