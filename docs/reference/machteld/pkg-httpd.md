---
id: machteld/package/httpd
type: package
title: Serving loopback HTTP
summary: Serve pages and bounded binary or text responses to clients on the local Windows PC.
commands: machteld::httpd, ::machteld::httpd::listen, httpd listen, machteld::httpd::listen
---

# Serving loopback HTTP

## Usage

`package require machteld::httpd 1.0` provides `::machteld::httpd::listen handler ?-port number?`. The handler is a nonempty Tcl command prefix. The port is 0 through 65535. The default, 0, requests an available port. The returned object exposes `port`, `address` and `close`. It binds IPv4 address `127.0.0.1`.

The handler receives one dictionary with `method`, `target` including its query string, `headers` mapping lowercase names to lists of values, and binary `body`. Return either `text` for UTF-8 or `bytes` for a binary response. Optional `type` overrides the default media type and `status` selects an HTTP status from 200 through 599. Statuses 204 and 304 require an empty body. HEAD invokes the handler and sends headers only.

## Example

```tcl
package require machteld::httpd 1.0
proc serve {request} {
    if {[dict get $request target] eq "/health"} {return [dict create text ready]}
    return [dict create status 404 text "Unknown path"]
}
set site [::machteld::httpd::listen serve]
puts "http://127.0.0.1:[$site port]/health"
# The application's Tcl or Tk event loop delivers requests.
# During shutdown call $site close.
```

## Errors and lifetime

Malformed listen options raise `MACHTELD HTTPD usage` or `badvalue`. Socket bind failures raise Tcl socket errors. A callback exception or invalid result sends HTTP 500. Unsupported methods receive 405. The server accepts HTTP/1.0 and 1.1 GET, HEAD and POST with Content-Length framing. HTTP/1.1 requires the local authority matching the listener's port. Transfer-Encoding receives 501 and Expect receives 417.

Each connection serves one request and expires after 15 seconds. Limits are 32 clients, 16 KiB of headers, 1 MiB of request body and 4 MiB of response body per connection. Closing the server releases all sockets and timers. Keep handlers short to allow other clients and Tk events to progress. The application authenticates state-changing requests. For an outgoing client, see `machteld/command/http`.
