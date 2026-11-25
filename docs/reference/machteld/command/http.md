---
id: machteld/command/http
type: command
title: http
summary: Send HTTP and HTTPS requests and stream binary responses through Windows WinHTTP.
commands: http, http get, http post, http stream
---

# http

Applications can also serve local pages using the runtime's
`machteld::httpd` package. [Loopback server](#loopback-server)

## Synopsis

```tcl
http get url ?-headers dict? ?-timeout duration? ?-agent name? \
    ?-maxbody size? ?-redirect none?
http post url body ?-headers dict? ?-timeout duration? ?-agent name? \
    ?-type mediaType? ?-maxbody size? ?-redirect none?
http stream url ?-headers dict? ?-timeout duration? ?-agent name? \
    ?-maxbody size? ?-redirect none?
```

## Arguments and options

- `url` must be HTTP or HTTPS and contain no newline or NUL. URL fragments are
  client-side and are not sent.
- `-headers dict` supplies request headers. Header names and values reject
  control/newline injection; names also reject colon and whitespace controls.
- `-timeout` defaults to `30s`, must be positive, and applies separately to
  WinHTTP network phases rather than to the complete operation. The converted
  value is limited to `2147483647` milliseconds.
- `-agent` defaults to `machteld`.
- `-maxbody` takes a positive binary size. For `get` and `post` it defaults
  to 64 MiB. A stream can run indefinitely within the host's signed byte count.
- `-redirect` takes exactly `none`: the first 3xx response returns normally
  with its `location` header, and no second request is issued to anyone - so
  no caller-supplied header or body is forwarded. Use it on every
  authenticated request carrying manual Authorization or Cookie headers. Any
  other value is `HTTP badvalue`. Omitted, redirects follow as documented.
- `post` sends a bytearray `body` byte-for-byte and any other value as UTF-8, so
  a JSON-encoded string posts correctly whatever it contains. `-type` sets
  Content-Type; otherwise an explicit Content-Type header is retained, or
  `application/octet-stream` is used.

## Results

`get` and `post` return a dict with integer `status`, cooked lowercase `headers`, original
`rawheaders`, bytearray `body`, and byte count `bytes`. Repeated response headers
are joined with comma-space in the cooked dict.

## Errors

Raised codes are `HTTP badvalue`, `HTTP notfound`, `HTTP oserror`,
`HTTP timeout`, `HTTP tls`, `HTTP toobig`, and `HTTP usage`. HTTP status codes
are returned normally rather than raised.

## Lifetime and timeouts

Each request owns its WinHTTP session, connection and request handles.
Timeouts apply to each network phase. Redirects and body reads can make elapsed
time exceed one timeout value. `get` and `post` are synchronous. `stream`
uses the Tcl event loop for readiness notifications.
A timeout or transport error does not establish whether a POST took
effect at the server; retry only with application-level replay safety.

## Examples

```tcl
set r [http get https://example.com/data -timeout 10s -maxbody 8M]
if {[dict get $r status] == 200} {
    set doc [json decode [dict get $r body]]
}

set body [json encode -dict {name machteld}]
http post https://example.com/api $body -type application/json
```

## Constraints

HTTPS uses system trust, proxy discovery, redirects, and transport decoding.
HTTPS-to-HTTP downgrade redirects are refused. There is deliberately no option
to disable certificate validation. A body over `-maxbody` is rejected, never
returned as plausible truncation.
`get` and `post` hold the complete response body in memory. Request data
already exists in memory before sending. For a GUI, use `stream` to consume
a response as it arrives or run synchronous work in a supervised worker.

## Subcommands

<a id="get"></a>
### get

#### Synopsis

`http get url ?-headers dict? ?-timeout d? ?-agent name? ?-maxbody size? ?-redirect none?`

#### Arguments and options

Accepts the common request options; `-type` is invalid for GET.

#### Results

Returns the fixed response dict including a bytearray body.

#### Errors

Uses the `HTTP` codes above for URL, transport, TLS, timeout, and size failures.

#### Lifetime and timeouts

Synchronous request; network phase default is 30 seconds.

#### Examples

`set response [http get https://example.com -maxbody 1M]`

#### Constraints

The method is exactly GET and has no request body.

#### See also

`machteld/command/http#post`.

<a id="post"></a>
### post

#### Synopsis

`http post url body ?common options? ?-type mediaType?`

#### Arguments and options

Bytearray `body` is sent byte-for-byte; other values are encoded as external
UTF-8. Explicit `-type` takes precedence over a Content-Type supplied in
`-headers`.

#### Results

Returns the same response dict as GET.

#### Errors

Uses the `HTTP` codes above and rejects missing body or GET-only syntax.

#### Lifetime and timeouts

Synchronous request with phase-based timeouts.

#### Examples

`http post $url $bytes -type application/octet-stream`

#### Constraints

Only POST and GET are exposed; this is not a general HTTP client surface.

#### See also

`machteld/command/json`.

<a id="stream"></a>
### stream

#### Synopsis

`http stream url ?common GET options?` returns a command handle immediately.

#### Arguments and options

Use GET options for request headers, the user agent, redirects, the network
phase timeout and an optional total response byte limit. Windows provides
TLS certificate validation and automatic proxy discovery.

#### Results

`$handle next` returns a dictionary with an `event` field.

| Event | Additional fields |
| --- | --- |
| `pending` | Windows is waiting for the next network operation. |
| `headers` | `status`, `headers` and `rawheaders` match a synchronous GET. `url` is the final response URL after redirects. |
| `data` | `data` contains a binary chunk of at most 65,536 bytes. |
| `eof` | The response is complete. |
| `cancelled` | The application cancelled this transfer. |

`$handle readable commandPrefix` arranges one callback on the Tcl event loop
when the next event or error is ready. The callback receives the handle as its
last argument. Register again when the application can accept more, or pass
an empty prefix to remove a pending callback.

#### Errors

`next` raises the usual structured HTTP errors, including `HTTP tls`,
`HTTP timeout` and `HTTP toobig`. The stream retains a terminal error until
the application closes the handle. HTTP response statuses arrive as headers.

#### Lifetime and timeouts

`$handle cancel` cancels an open request, including a request waiting for
headers or more body data. `$handle close` releases the command and stops
any outstanding request. Interpreter deletion also closes its streams.

#### Examples

```tcl
proc consumeResponse {output handle} {
    try {
        set item [$handle next]
        switch [dict get $item event] {
            data {puts -nonewline $output [dict get $item data]}
            eof - cancelled {$handle close; return}
        }
        $handle readable [list consumeResponse $output]
    } on error {message options} {
        $handle close
        return -options $options $message
    }
}
set output [open response.bin wb]
set handle [http stream $url -timeout 15s]
$handle readable [list consumeResponse $output]
```

The application owns the output channel and closes it after the transfer.

#### Constraints

The runtime allows one outstanding operation and one 64 KiB body buffer per
stream. Windows maintains transport buffers, and the caller owns the chunks
it retains. A consumer can pause between reads.

#### See also

`machteld/command/http#get`.

<a id="loopback-server"></a>
## Serving a local page

`package require machteld::httpd` loads the built-in server. Call
`::machteld::httpd::listen handler ?-port number?` with a Tcl command
prefix. The default port is assigned by Windows. The returned object
supports `port`, `address` and `close`. Closing it releases the listener
and all accepted connections.

```tcl
package require machteld::httpd
proc page request {
    switch -- [dict get $request target] {
        / {return [dict create type {text/html; charset=utf-8} text {<h1>Catalogue</h1>}]}
        /time {return [dict create type application/json text [json encode -dict [dict create seconds [clock seconds]]]]}
        default {return [dict create status 404 text {Page not found}]}
    }
}
set site [::machteld::httpd::listen page]
set url http://127.0.0.1:[$site port]/
# Tk's event loop serves requests while the window is open.
# When the application finishes serving, call `$site close`.
```

The handler receives a dictionary with `method`, `target`, `headers` and
`body`. The target preserves its query string. Header names are lowercase,
and each header value is a list. The body is a bytearray. Return a dictionary
with one of `text` (encoded as UTF-8) or `bytes` (a bytearray). Optional
`type` and `status` default to a suitable content type and HTTP 200.
A handler error returns HTTP 500. A HEAD request calls the handler and sends
the resulting headers.

The listener binds to IPv4 loopback and accepts HTTP/1.0 and HTTP/1.1
GET, HEAD and POST. A request body uses Content-Length framing. Each
connection serves one request. The server accepts up to 32 simultaneous
connections, 16 KiB of headers, 1 MiB of request data and 4 MiB of
response data per connection. A connection expires after 15 seconds.
Handlers run in the application's Tcl event loop. Move long work to a
worker so Tk and other requests can keep running. Applications own
authorization for any route that changes state.

## See also

`machteld/command/json`, `machteld/guide/ecosystem-policy`.
