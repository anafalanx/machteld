---
id: machteld/command/http
type: command
title: http
summary: Perform bounded HTTPS GET and POST requests through Windows WinHTTP.
commands: http, http get, http post
---

# http

## Synopsis

```tcl
http get url ?-headers dict? ?-timeout duration? ?-agent name? \
    ?-maxbody size? ?-redirect none?
http post url body ?-headers dict? ?-timeout duration? ?-agent name? \
    ?-type mediaType? ?-maxbody size? ?-redirect none?
```

## Arguments and options

- `url` must be HTTP or HTTPS and contain no newline or NUL. URL fragments are
  client-side and are not sent.
- `-headers dict` supplies request headers. Header names and values reject
  control/newline injection; names also reject colon and whitespace controls.
- `-timeout` defaults to `30s`, must be positive, and applies separately to
  WinHTTP network phases rather than to the complete operation.
- `-agent` defaults to `machteld`.
- `-maxbody` defaults to 64 MiB and must be a positive binary size.
- `-redirect` takes exactly `none`: the first 3xx response returns normally
  with its `location` header, and no second request is issued to anyone - so
  no caller-supplied header or body is forwarded. Use it on every
  authenticated request carrying manual Authorization or Cookie headers. Any
  other value is `HTTP badvalue`. Omitted, redirects follow as documented.
- `post` treats `body` as bytes. `-type` sets Content-Type; otherwise an explicit
  Content-Type header is retained, or `application/octet-stream` is used.

## Results

Returns a dict with integer `status`, cooked lowercase `headers`, original
`rawheaders`, bytearray `body`, and byte count `bytes`. Repeated response headers
are joined with comma-space in the cooked dict.

## Errors

Raised codes are `HTTP badvalue`, `HTTP notfound`, `HTTP oserror`,
`HTTP timeout`, `HTTP tls`, `HTTP toobig`, and `HTTP usage`. HTTP status codes
are returned normally rather than raised.

## Lifetime and timeouts

Each request owns its WinHTTP session, connection, and request handles only for
the call. Timeouts are per phase; redirects and body reads can make wall-clock
time exceed one timeout value.

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

`body` is sent byte-for-byte. Explicit `-type` takes precedence over a
Content-Type supplied in `-headers`.

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

## See also

`machteld/command/json`, `machteld/guide/ecosystem-policy`.
