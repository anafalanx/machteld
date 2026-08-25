# Machteld improvements for reusable WebSocket and CDP work

Status: implementation handoff  
Date: 2026-08-25  
First consumer: FlowNet KFX History

## Objective

Make repeated WebSocket and Chromium DevTools Protocol (CDP) use safe,
bounded, and self-documenting. Incubate the reusable packages without silently
making them part of every Machteld host; runtime admission requires a second
named consumer or an explicit owner waiver recorded against Machteld's
Direction criteria. Keep browser-product policy out of Machteld.

The desired layering is:

1. Machteld core: exact JSON values, safe HTTP redirects, and the native
   primitives required by a bounded transport.
2. An opt-in, application-carried WebSocket package during incubation.
3. A separate opt-in CDP router package built on WebSocket and JSON.
4. Optional browser-controller packages built on `child` and CDP.
5. Product policy, such as EBP login and credential-capture rules, in the
   application.

This is not a request to turn Machteld into Playwright or Selenium.

## Short priority list

1. Assign a new Machteld release; 0.14.0 must remain internally consistent.
2. Add typed/strict JSON values.
3. Add exactly `http -redirect none` without redesigning existing follow
   behavior.
4. Establish the private bounded asynchronous-delivery covenant.
5. Incubate a loopback-only `machteld::websocket` Tcl package.
6. Build a separate `machteld::cdp` Tcl router above it.
7. Admit either package to every host only after a second concrete consumer or
   an explicit owner waiver.
8. Keep Edge control reusable but outside the native palette, and keep all EBP
   rules in KFX.
9. Resolve KFX raw-access persistence versus profile-only recapture before
   migration; that decision determines whether DPAPI is required.

## Working constraints

- All builds and tests run locally. Do not introduce GitHub CI or other remote
  build execution.
- Do not use real credentials in tests, logs, fixtures, process arguments, or
  environment variables.
- Preserve provenance from the current KFX and FlowNet Lab mechanisms. The
  minimum provenance set is:

  - `kfx-history/edge-cdp.tcl` and `kfx-history/tests/cdp.test`;
  - `kfx-history/edge-login.tcl` and
    `kfx-history/tests/edge-login.test`;
  - `kfx-history/ebp-login.py` and
    `kfx-history/tests/test_ebp_login.py` as the development oracle only;
  - `_flownet-lab/Live IO data/readme.md` and the original subscribed WebSocket
    mechanism that established the exact `Real time`/`Zoeken` acquisition
    sequence.

  Treat these as incubation evidence, not as unquestioned production code.
- Do not remove the application-local oracle until the new package passes
  parity, wrapped-host, and cleanup gates.
- Core P0 changes must agree across the released executable, direct Tcl host,
  wrapped console host, and wrapped GUI host: version, commands, behavior,
  manifest, errors, and embedded documentation. During package incubation, the
  bare host is not required to expose application-carried packages; compare the
  source-run application with its wrapped application instead.
- The current `dev/machteld` directory contains released artifacts and
  application work, not the Machteld C source tree. Locate the authoritative
  source before attempting a native change.

## Current evidence

Machteld 0.14 already has the important composition primitives: supervised
process trees (`child` and `scope`), Tcl/Tk, asynchronous Tcl channels and
timers, CNG hashing/randomness, bounded HTTP, JSON, `canon`, `links`, and
single-EXE `wrap`.

Two concrete runtime gaps have been demonstrated:

1. The JSON encoder cannot express every JSON type unambiguously. A Tcl boolean
   produced by `expr` encodes as the string `"true"`/`"false"` in the exact
   Machteld 0.14.0/Tcl 9.0.4 runtime, while a decoded JSON boolean re-encodes as
   the number `1`/`0`. The observed probes are therefore neither JSON boolean
   `true` nor `false`. Null, empty string, false, nested empty containers, and
   number-looking strings are likewise ambiguous. CDP requires literal JSON
   booleans.
2. `machteld::http` follows redirects and has no refusal option. Authenticated
   requests carrying manually supplied Authorization or Cookie headers must
   not use that transport until it can refuse redirects.

The existing pure-Tcl WebSocket/CDP prototype proves that browser control over
a loopback CDP socket is possible with current primitives. Its existence does
not remove the need for a reusable, reviewed package contract.

Before adding any contract, assign the work to a new Machteld release (likely
the next minor release, but verify the authoritative source first). Do not add
JSON types/options, HTTP options, packages, error domains, manifest entries, or
documentation while still claiming 0.14.0. The package version, `version`,
roadmap, manifest, docs, direct host, and both wrapper hosts must agree.

## P0: required core changes

### 1. Typed and strict JSON

Add an explicit typed JSON representation while retaining the existing plain
mode for compatibility.

The exact spelling must be designed contract-first, but the API must provide:

- constructors for JSON string, number, boolean, null, array, and object;
- `json encode` recognition of those values at every nesting level;
- a typed decode mode;
- a way to inspect a typed value's JSON type and obtain its value;
- strict typed decoding that rejects duplicate object members and unpaired
  Unicode surrogates.

One possible shape is:

```tcl
json value string TEXT
json value number LITERAL
json value boolean BOOLEAN
json value null
json value array LIST
json value object DICT
json decode -typed TEXT
json type VALUE
json unwrap VALUE
```

This is a design sketch, not a frozen command contract. Prefer opaque Tcl
object types, or an equally collision-proof WJO-style representation, over
magic strings or user-visible sentinel dicts.

Required laws:

- `null`, `false`, `true`, `0`, `"0"`, and `""` remain distinct.
- Empty object and empty array remain distinct at every nesting level.
- An explicitly typed string that looks like a number remains a string.
- Number spelling is preserved, including `-0`, exponents, and integers beyond
  64-bit range.
- Typed values survive ordinary list/dict nesting and copying within one Tcl
  interpreter without losing their JSON identity. Arbitrary stringification,
  SQLite storage, worker/engine transport, or interpreter boundaries are not
  promised to preserve the opaque type.
- Typed decode rejects duplicate keys and unpaired surrogates by default.
- Existing plain decode/encode behavior remains available and documented.
- Existing depth limits remain. Typed decode has a documented default byte
  limit, a documented hard cap, and an explicit option that can request a
  lower limit; it does not attempt to infer what a caller bounded elsewhere.

Do not solve this with hand-authored JSON fragments, string substitution at
call sites, automatic coercion, a schema language, or an unrestricted
`json raw` escape hatch.

Minimum acceptance tests:

- exact wire output for all six scalar distinctions above;
- exact literal `true` for CDP `flatten`, `returnByValue`, and `userGesture`,
  plus exact literal `false` for `awaitPromise`;
- nested empty objects and arrays;
- numeric-looking session IDs forced to JSON strings;
- rejection of duplicate `id`, `sessionId`, and nested keys in strict mode;
- rejection of every unpaired-surrogate form;
- depth and size-limit fixtures;
- parity in direct, console-wrapped, and GUI-wrapped hosts.

### 2. Explicit HTTP redirect policy

The minimum required addition is:

```tcl
http get  URL ... -redirect none
http post URL BODY ... -redirect none
```

With `none`, Machteld must return the first 3xx response normally, including
its `Location` header, and must issue no request to the redirect target.

P0 is deliberately only `-redirect none`. Preserve the existing behavior when
the option is omitted. Values such as `same-origin`, changes to `follow`,
cross-origin header stripping, and a total wall-clock deadline require their
own consumer, contract, and compatibility review; they are not hidden inside
this change.

Non-negotiable security laws:

- Under `none`, no second request is issued, so no caller-supplied header or
  request body is forwarded anywhere. The runtime does not guess which custom
  headers are "sensitive".
- Existing omitted-option redirect and phase-timeout behavior remains exactly
  as documented for the target release.
- In the new `-redirect none` path, URL, query, header, cookie, and
  response-body data never enter error text or diagnostic logs. Do not claim a
  new redaction law for omitted-option modes without separately verifying and
  versioning it.

Do not add redirect callback scripts, arbitrary WinHTTP flag access, or a
redirect-policy DSL.

Minimum acceptance tests:

- 301, 302, 303, 307, and 308 responses all stop at the first response under
  `none`, for relative and absolute `Location` values and for same-origin and
  cross-origin targets;
- the target fixture receives zero requests;
- Authorization and Cookie sentinels are absent at the target and from every
  diagnostic surface;
- omitted-option HTTPS-downgrade and phase-timeout behavior remains unchanged;
- the option appears in the manifest and embedded documentation in every host
  type.

### 3. A private bounded asynchronous-delivery covenant

Any reusable network implementation must use one internal delivery discipline:

- OS/native and channel callbacks enqueue data; they never evaluate application
  Tcl directly. A later internal delivery step may invoke the explicitly
  registered handle-only notifier under the remaining rules below.
- Public timer/event scripts contain only opaque handles or delivery IDs.
- Payload queues have both count and byte limits, per handle and in aggregate
  per owning Tcl interpreter. A future native process-wide cap must be named
  separately rather than being implied by "global".
- A terminal event has reserved capacity so queue saturation can always be
  disclosed generically.
- Cancellation and close purge payloads and decrement every counter exactly.
- Stale notifications become no-ops.
- Callback or notifier failure is caught, cleanup runs, and only fixed error
  tokens escape.
- Nothing reaches `bgerror` or Tk's default modal-error path.
- Wire payload, URL query, headers, selected subprotocol, close reason, and
  peer-controlled text never appear in errors, traces, `info`, logs, manifests,
  or scheduled scripts.

Prefer a pull interface. If a readiness callback exists, it receives only the
opaque handle; the application must explicitly call `receive` to obtain data.
Do not expose the dispatcher as a general-purpose `eval` facility.

## P1A: reusable WebSocket package

The owner's stated future reuse justifies contract and incubation work, but one
current consumer does not automatically satisfy Machteld's runtime-admission
rule. Extract the hardened loopback machinery into an opt-in, self-documented,
application-carried Tcl package. Admit it to every Machteld host only after a
second concrete consumer exists or the owner records an explicit admission
waiver. Keep its public contract backend-neutral so a native WinHTTP
implementation can replace it later without changing applications.

During incubation, load it explicitly and expose no global aliases:

```tcl
package require machteld::websocket 0.1.0
::machteld::websocket start ...
```

Before admission, define whether optional package facts live in a package-local
manifest or in a new lazy-package section of `::machteld::manifest`. Loading a
package must not mutate unrelated core command facts.

A candidate shape is:

```tcl
::machteld::websocket start URL ?OPTIONS?
::machteld::websocket send HANDLE text STRING
::machteld::websocket send HANDLE binary BYTES
::machteld::websocket receive HANDLE
::machteld::websocket info HANDLE
::machteld::websocket list
::machteld::websocket close HANDLE ?-code CODE? ?-reason STRING?
```

Candidate start options are:

```text
-headers DICT
-subprotocols LIST
-connect-timeout DURATION
-onready COMMAND_PREFIX
-max-handshake-header BYTES
-max-handshake-headers COUNT
-max-frame BYTES
-max-message BYTES
-max-queued COUNT
-max-queued-bytes BYTES
-max-outgoing COUNT
-max-outgoing-bytes BYTES
```

Version one is explicitly event-driven:

- `start` returns a connecting handle without pumping the Tcl event loop.
- Transport progress occurs only while the owning interpreter's normal event
  loop runs.
- Version one is therefore for event-loop-owning programs. It never calls
  `update` or `vwait` internally; a linear/blocking facade requires a separate
  contract rather than hidden nested-loop reentrancy.
- `receive` is nonblocking and never starts a nested event loop; it drains the
  current bounded event batch.
- `-onready` is optional and edge-triggered on an empty-to-nonempty queue
  transition. It receives only the handle, is caught/sanitized under the
  private-delivery covenant, and rearms only after `receive` fully drains the
  queue.
- `send` only validates and accepts a message into the bounded outgoing path;
  it does not promise peer receipt or a socket flush. Remove `-timeout` until a
  separately useful, precisely defined send-wait operation exists.
- `close` best-effort sends a valid close frame when possible, immediately
  disables events, purges queues, closes the channel, and invalidates the
  handle. It does not pump or wait for the peer. Test silent peers and saturated
  output explicitly.
- A peer close or transport failure makes the handle terminal and queues its
  reserved terminal event; the handle remains readable/observable until the
  owner explicitly closes it.
- In terminal state, `info` reports only safe state/count fields, `receive`
  drains the reserved terminal event and then returns an empty batch, and
  `send` raises `badstate`. The handle never invalidates itself; explicit
  `close` invalidates it and may deliberately discard an unread terminal event.

The exact `receive` event dicts must be frozen before implementation. At
minimum they distinguish:

```text
{type open protocol SELECTED_PROTOCOL}
{type text data STRING}
{type binary data BYTEARRAY}
{type close code CODE reason STRING clean FLAG}
{type failure category FIXED_TOKEN}
```

The selected protocol and peer close reason are payload-bearing values exposed
only through this explicit receive result, never through `info` or diagnostics.

Version-one scope:

- WebSocket client only; no server.
- Plain `ws://` only to numeric loopback addresses (`127.0.0.1`, and `::1` if
  implemented and tested).
- Strict RFC 6455 handshake and framing.
- Text and binary messages with preserved boundaries and type.
- Exact subprotocol negotiation.
- Automatic bounded ping/pong handling.
- Explicit connect/handshake deadline.
- Explicit limits for handshake-header bytes/count, frame bytes, message bytes,
  queued-event count, queued bytes, outgoing count/bytes, and live handles.
- No compression, public fragmentation controls, automatic reconnect, replay,
  cookie jar, ambient browser state, or redirects.

The connect/handshake deadline is serviced only while the owning Tcl event loop
runs. It is not an autonomous Job-style deadline, and the documentation must
say so.

Suggested starting limits, to be confirmed by measured fixtures:

- frame: 8 MiB;
- message: 16 MiB;
- per-handle receive queue: 64 messages and 32 MiB;
- per-interpreter aggregate receive queue: 256 messages and 64 MiB;
- outgoing queue: 16 messages and 16 MiB;
- fixed per-interpreter live-handle cap: 32.

Requested limits may be lowered freely and raised only up to documented hard
caps. Saturation closes only the causative connection with a fixed `limit`
failure; it must not silently drop messages.

Required protocol laws:

- Client frames are masked with system randomness.
- Server masking, nonzero RSV bits, reserved opcodes, non-canonical lengths,
  invalid 64-bit high bits, fragmented control frames, invalid close codes,
  and invalid UTF-8 fail closed.
- Fragmented text is validated after correct reassembly; ping/pong may occur
  between continuations.
- No user-supplied connection-control header can override the handshake.
- Header names/values have strict syntax, count, and byte limits. Connection,
  Upgrade, Host, Sec-WebSocket-Key, Sec-WebSocket-Version, and extension
  negotiation cannot be supplied through `-headers`.
- URL userinfo and fragments are rejected.
- Query strings may be carried on the wire but are never diagnostic data.
- A selected subprotocol must be exactly one offered value.
- Handles are interpreter-owned, explicitly closed, and closed at interpreter
  teardown. Align stale-handle and repeated-close behavior with Machteld's
  existing handle convention rather than inventing a special rule.

Separate synchronous raised errors from asynchronous terminal outcomes, in the
same way Machteld separates `codes` from protocol `replycodes`:

```text
raised codes: usage|badvalue|nohandle|badstate|oserror
terminal categories: timeout|protocol|limit|oserror|notifier
```

Runtime connect, framing, queue, peer, and notifier failures become the one
reserved `{type failure category FIXED_TOKEN}` event; they are not raised later
through `bgerror`. If `send` itself detects saturation, its contract must return
a fixed non-accepted result while transitioning the handle to terminal, rather
than ambiguously both raising and queuing the same failure.

Add a `tls` code only when `wss://` support is actually admitted.

### When to make WebSocket native

The current pure-Tcl transport is sufficient for loopback CDP. Promote the
backend to a native WinHTTP WebSocket client when either:

- the first real `wss://` consumer is admitted;
- proxy/system-TLS behavior is required; or
- measurement demonstrates a material correctness, latency, or memory benefit.

A native implementation must retain the same handle and limit contract. For
remote WebSockets, require `wss://` with system certificate validation and no
disable switch. Do not claim general remote support until TLS, proxy,
authentication, redirects, and header handling have dedicated fixtures.

## P1B: separate CDP router package

CDP belongs above WebSocket as a documented Tcl package. It should not be a C
primitive unless later measurement proves JSON routing to be a bottleneck.

During incubation it is loaded and called explicitly:

```tcl
package require machteld::cdp 0.1.0
::machteld::cdp start ...
```

It depends on the exact compatible `machteld::websocket` package version and
exposes no global aliases.

A candidate shape is:

```tcl
::machteld::cdp start URL ?WEBSOCKET_OPTIONS? ?CDP_OPTIONS?
::machteld::cdp request HANDLE METHOD PARAMS ?-session SESSION_ID?
::machteld::cdp notify HANDLE METHOD PARAMS ?-session SESSION_ID?
::machteld::cdp receive HANDLE
::machteld::cdp abandon HANDLE REQUEST_ID
::machteld::cdp info HANDLE
::machteld::cdp list
::machteld::cdp close HANDLE
```

CDP-specific start options must include at least:

```text
-onready COMMAND_PREFIX
-events METHOD_LIST
-max-pending COUNT
-max-tombstones COUNT
-max-queued COUNT
-max-queued-bytes BYTES
```

Caps also have documented hard maxima and a per-interpreter aggregate byte
limit. `-events` is an exact CDP-method allowlist applied before event payloads
enter the CDP queue; responses to owned requests are never filtered.

Like WebSocket, `start` returns a connecting handle and `-onready` is a
handle-only, edge-triggered queue-readiness notifier. CDP queues a `{type open}`
event only after the underlying WebSocket is open and owned. `request` and
`notify` before that event are rejected with synchronous `badstate`; they are
never silently queued.

CDP inherits the WebSocket terminal-handle lifecycle exactly: close/failure
queues one reserved terminal event; the handle remains valid for safe `info`
and nonblocking `receive` until explicit `close`; after the terminal event is
drained, `receive` returns an empty batch; `request` and `notify` raise
`badstate`; and `close` invalidates the handle and may discard an unread
terminal event.

`abandon` is local bookkeeping only. CDP has no generic command-cancellation
operation: the browser may still execute the command, and one matching late
response is consumed by a bounded tombstone rather than delivered. Tombstone
exhaustion fails the causative handle generically instead of evicting an older
tombstone silently.

Freeze exact receive shapes before implementation. A recommended tagged
contract is:

```text
{type open}
{type response id ID session SESSION result TYPED_JSON_VALUE}
{type error-response id ID session SESSION code CODE message TEXT data VALUE}
{type event method METHOD session SESSION params TYPED_JSON_VALUE}
{type close category FIXED_TOKEN}
{type failure category FIXED_TOKEN}
```

Use an empty `session` only where browser-level protocol semantics permit it.
Browser-provided error `message` and `data` are explicit returned data, never
raised diagnostic text. Document which optional fields are present rather than
silently varying dict shape.

Required laws:

- A CDP handle exclusively owns its WebSocket; there are no competing readers.
- Request IDs are bounded canonical positive integers and are never reused.
- Every pending request records its expected flattened `sessionId`.
- A session request accepts only a response carrying that exact, case-sensitive
  session. A browser-level request rejects an unexpected session.
- Event session IDs are validated and returned as a separate field.
- Response, event, and error-response shapes are distinguished exactly.
- Unknown or duplicate responses fail closed. Explicit local abandonment uses
  the bounded tombstone table described above.
- Pending requests, tombstones, raw queued messages, decoded messages, and
  aggregate bytes are all bounded.
- On arrival, typed-decode the bounded envelope long enough to validate shape
  and extract only bounded routing metadata (`id`, `method`, and `sessionId`),
  then discard that decoded tree and queue the bounded raw message plus its
  metadata. Decode once more when the consumer calls `receive`. Do not retain a
  second decoded-object copy.
- Optional event-method filtering occurs before unwanted large events enter
  the application queue.
- Browser-provided error messages are returned as data when needed; they are
  never interpolated into raised error text.
- Close removes every request, tombstone, and message.
- The router uses typed/strict JSON and never assembles raw JSON fragments.

Separate synchronous raised errors from asynchronous terminal outcomes:

```text
raised codes: usage|badvalue|nohandle|badstate|notfound|limit
terminal categories: transport|protocol|session|limit|notifier
```

Local `abandon` does not produce a `cancelled` error. Its observable effect is
only that one later matching response is consumed by the bounded tombstone.

Do not generate Tcl commands for the complete evolving CDP schema. Do not add
DOM selectors, click helpers, navigation policy, JavaScript helpers, or
Playwright-like behavior.

## P2: reusable browser control, outside the native core

After a second browser-control consumer exists, or after an explicit owner
admission decision, a separate Tcl package may provide:

- installed-Edge discovery through an explicit adapter;
- dedicated per-user profile creation and exclusive use;
- one Job-owned, visible, attended browser;
- `--remote-debugging-port=0` and loopback-only debugging;
- strict, bounded `DevToolsActivePort` readiness and parsing;
- exact target discovery/attachment;
- `Browser.close` followed by `child close` as the ownership fallback.

It must never:

- attach to a user's ordinary browser or shared profile;
- launch the browser with `detach`;
- discover or kill browsers by process-name/PID snapshots;
- expose remote debugging on a non-loopback interface;
- put credentials in argv or environment;
- contain site-specific login, selectors, routes, or capture policy.

Machteld's existing `child` command already supplies the essential process-tree
ownership primitive. A browser command in the native palette is not required.

## Evidence-gated Windows conveniences

These may benefit multiple future applications, but none is admitted merely to
finish the transport work:

1. A known-folder command that resolves `FOLDERID_LocalAppData` from the current
   Windows token instead of trusting an environment variable.
2. A narrow installed-application/App Paths resolver returning a canonical
   executable identity without launching it or changing `child` lookup rules.
   Keep this explicitly deferred: Machteld's Direction rejects
   environment-specific resolvers, so admission requires multiple concrete
   consumers and a separately reviewed generic contract.
3. Current-user DPAPI protect/unprotect for bytearrays. This becomes a concrete
   requirement if KFX chooses to persist captured raw access; it remains
   unnecessary if KFX persists only the Edge profile and recaptures access in
   every new process.
4. A handle-based per-user state-directory primitive only after its attacker
   model is written. `canon` and `links` are snapshots and cannot eliminate a
   same-user TOCTOU race; do not claim otherwise.

Do not invent a "secret Tcl string" that promises interpolation cannot copy a
secret. Prefer short lifetimes, bounded private queues, redacted diagnostics,
and no persistence.

## Product policy that must remain in KFX/FlowNet

The following are not Machteld features:

- EBP host, origin, routes, cookie scope, and case-sensitive WebSocket paths;
- the accessible `Real time` labels and exact `Zoeken` control;
- ambiguity refusal and the exact capture-arming interval;
- correlation of captured authorization with the exact allowlisted EBP socket,
  CDP target/session/request ID, and observed 101 response;
- authorization/cookie validation and bounds;
- the exact integrated-auth allowlist (`ebpportal.infrabel.be`, never a wildcard
  without separate approval);
- the rule that attended SSO authorizes local use;
- the dedicated profile's retention policy;
- the unresolved access-persistence decision and renewal UX. Existing work
  authorized a per-user `subscribed.env`; the stricter profile-only alternative
  stores no raw access but must launch Edge and recapture it in every new app
  process. Resolve and document this product decision explicitly before
  implementation. If raw access persists, define DPAPI protection and migration
  rather than silently retaining plaintext;
- KFX history interpretation and catalogue retry behavior.

RFC 6455 upgrade/accept-proof validation is WebSocket-package work. Generic
flattened response/event session validation is CDP-package work. KFX owns only
the additional correlation to the exact EBP traffic it is authorized to
capture.

## API designs explicitly out of scope

- `browser login`, `browser capture-cookie`, or `browser click`.
- A Playwright/Selenium clone or generated bindings for all CDP methods.
- Raw JSON-value escape hatches.
- Full-message `-onmessage` callback scripts.
- Unbounded queues, implicit retry, reconnect, or replay.
- Automatic cookie jars, SSO, or credential refresh in `http` or WebSocket.
- TLS-certificate validation bypasses.
- Runtime-global replacement of Tcl/Tk `bgerror`.
- Python, Node, Playwright, `z`, or another sidecar as a published dependency.
- Bundling Chromium merely to call the result a single executable.
- Weakening `child`'s deterministic PATH-only process resolution.

## Mandatory local conformance gates

### JSON

- All type distinctions and strict failures listed under P0.
- Exact CDP request wire text containing literal booleans.

### HTTP

- A two-server redirect canary proving that no second request or sensitive
  header crosses under `-redirect none`.
- 301/302/303/307/308, relative/absolute `Location`, same-origin/cross-origin,
  unchanged omitted-option behavior, and diagnostic-redaction fixtures.

### WebSocket protocol

- RFC accept and masking vectors.
- Every incremental split point used against the handshake and representative
  frames.
- Incoming and outgoing boundaries at 125/126/65535/65536 bytes.
- Invalid 64-bit high bit and non-canonical length fixtures.
- Fragmented multibyte UTF-8 plus invalid final UTF-8.
- Ping/pong interleaved with continuations.
- Invalid close codes and close-reason UTF-8.
- Masked server frames, RSV bits, invalid opcodes, and fragmented controls.
- Per-handle and per-interpreter aggregate count and byte saturation.
- Exact accounting after receive, send failure, cancellation, protocol failure,
  close, and interpreter teardown.
- Stale notification and fault-injected channel/native callback fixtures.
- Loopback-only enforcement and redirect refusal.
- A proof that `start`, `send`, `receive`, and `close` never start a nested Tcl
  event loop, plus silent-peer and output-saturated close fixtures.

### CDP routing

- Request-ID correlation and out-of-order responses.
- Exact expected-session matching, including missing, mismatched, invalid, and
  unexpectedly present sessions.
- Validated and separately exposed event sessions.
- Duplicate, unknown, abandoned, and late responses.
- Pending/tombstone/event count and aggregate-byte saturation.
- Event filtering under a large irrelevant-event burst.
- Secret-bearing Network events appearing only transiently in their bounded
  private queue and in the explicit returned message; they disappear after
  receive or close and appear nowhere else.

### Secrecy and UI behavior

- Sentinel values are absent from `after info`, `errorInfo`, `errorCode`,
  `bgerror`, logs, state/info results, process argv/environment, and retained
  queues after cleanup.
- A throwing application callback/notifier produces no Tk dialog and exposes
  only a fixed category.
- Cancellation, timeout, peer close, malformed input, and app shutdown clear
  all handles and queues.

### Windows and packaging

- A local, non-network Edge smoke test may be explicit rather than part of the
  deterministic core gate.
- A second app instance cannot attach to or kill the first instance's browser.
- Unrelated Edge processes remain untouched.
- Stale/replaced `DevToolsActivePort`, reparse-point profile components, Edge
  absence, Unicode/spaced paths, cancellation, crash, and shutdown are covered.
- Final publication is tested from a fresh Windows user with only the wrapped
  executable and installed Microsoft Edge.
- No installed Tcl, Python, Playwright, `z`, repository checkout, writable app
  directory, or external network is required for the local smoke fixture.
- A wrapped executable can `package require` the exact incubated
  `machteld::websocket` and `machteld::cdp` versions without source-tree files.
  Their command surfaces, package metadata, documentation, and applicable
  manifest facts match the direct host.
- The newly assigned Machteld version agrees across `version`, package version,
  roadmap, manifest, embedded docs, direct host, wrapped console host, and
  wrapped GUI host.

## Recommended implementation order

1. Locate the authoritative Machteld source and record the current version and
   manifest as the baseline.
2. Assign and document the target Machteld release; update the roadmap and
   create version/manifest/docs/wrapper consistency gates before adding API.
3. Write the JSON and HTTP contracts, manifest changes, hostile fixtures, and
   documentation before implementation.
4. Implement typed/strict JSON; run every direct/wrapped parity gate.
5. Implement `http -redirect none`; run the redirect canary and secrecy gate.
6. Extract and finish the loopback WebSocket package from the KFX oracle,
   preserving provenance and closing all known review findings.
7. Build the separate CDP router on typed JSON and WebSocket.
8. Record a second concrete consumer or explicit owner waiver before embedding
   either incubated package in every Machteld host.
9. Resolve KFX's per-user raw-access versus profile-only persistence decision
   and its corresponding DPAPI/recapture behavior.
10. Migrate KFX to the packaged layers and remove its duplicate transport only
   after source and single-EXE verification pass.
11. Admit native WinHTTP `wss://` support only when a real remote consumer or
   measurements justify it.
12. Consider known folders, application discovery, and stronger
   state-directory handling only as separately evidenced additions.

At every phase, keep the tree locally green and stop on a failed security or
wrapped-host parity gate. Do not compensate for a missing primitive with an
unreviewed browser workaround.
