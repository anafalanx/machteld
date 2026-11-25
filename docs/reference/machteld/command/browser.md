---
id: machteld/command/browser
type: command
title: browser
summary: Launch and resume an app-owned Edge or Chromium session and observe page navigation.
commands: browser, browser launch, browser attach, browser navigate, browser wait, browser cancel, browser release, browser close
---

# browser

## Synopsis

`browser launch|attach|navigate|wait|cancel|release|close ...`

## Arguments and options

An application selects its own profile directory. Controller and navigation tokens belong to the interpreter that received them.

## Results

Launch and attach return controller tokens. Navigate returns a navigation token. Wait and cancel return a status dictionary.

## Errors

Errors use `MACHTELD BROWSER` followed by a specific code. `usage` identifies the wrong arguments and `oserror` a platform or filesystem error.

## Lifetime and timeouts

Only one controller can hold a profile at a time. Durations use explicit units such as `500ms` and `10s`.

## Examples

```tcl
set session [browser launch -profile [file join $appData browser]]
try {
    set nav [browser navigate $session $url]
    set result [browser wait $session $nav -timeout 30s]
} finally {
    browser close $session
}
```

## Constraints

An installed Edge or Chromium browser must permit an app-owned debugging session. The application owns sign-in, service-specific behaviour and profile retention. Protect the profile directory with the same access controls as the application's other private data.

## See also

`machteld/command/desktop`, `machteld/command/lock`.

<a id="launch"></a>
### launch

#### Synopsis

`browser launch -profile directory ?-executable path? ?-headless boolean? ?-timeout duration?`

#### Arguments and options

Choose a new or empty profile directory, or reuse a directory previously claimed by Machteld. Missing parent directories are created. `-executable` selects an installed `msedge.exe`, `chrome.exe` or `chromium.exe`. The default searches standard Edge and Chromium installation paths. `-headless` defaults to false.

#### Results

Returns an opaque controller token once the owned tab is available.

#### Errors

`ownership` identifies a mismatched marker, file or listener. `busy` means the profile already has a controller or live browser. `notfound` identifies an unavailable executable. `launch`, `closed`, `protocol` and `timeout` describe startup failures.

#### Lifetime and timeouts

Startup defaults to 30 seconds. An unsuccessful launch closes the process tree that this call created.

#### Examples

```tcl
set session [browser launch -profile [file join $appData browser]]
```

#### Constraints

The process starts with a separate Chromium user-data directory and a loopback-only control port. The browser's own sandbox remains enabled.

#### See also

`machteld/command/browser#attach`, `machteld/command/browser#close`.

<a id="attach"></a>
### attach

#### Synopsis

`browser attach -profile directory ?-timeout duration?`

#### Arguments and options

Supply the same owned profile used to launch the browser.

#### Results

Returns a fresh controller token for the recorded browser process and tab.

#### Errors

`closed` covers an ended browser session. `busy` means another controller holds the profile. `ownership` covers a directory, endpoint or process identity mismatch. A closed tab can return `protocol`.

#### Lifetime and timeouts

Attachment defaults to 30 seconds. A closed process can be replaced by calling `launch`.

#### Examples

```tcl
set session [browser attach -profile [file join $appData browser]]
```

#### Constraints

The directory identity, process creation time, loopback listener, endpoint and selected tab identify the session across controller restarts.

#### See also

`machteld/command/browser#launch`, `machteld/command/browser#release`.

<a id="navigate"></a>
### navigate

#### Synopsis

`browser navigate session url`

#### Arguments and options

Pass a live controller and an HTTP or HTTPS URL. Supply escaped URLs for literal spaces.

#### Results

Returns a navigation token immediately. A subsequent navigation replaces the previous completed token.

#### Errors

`busy` means the previous navigation is pending. `badvalue` identifies an unsupported URL. `closed` identifies an expired controller or connection.

#### Lifetime and timeouts

Use `wait` to observe the selected navigation or `cancel` to stop it.

#### Examples

```tcl
set nav [browser navigate $session $url]
```

#### Constraints

One navigation may be pending per controller. The application chooses the URL.

#### See also

`machteld/command/browser#wait`, `machteld/command/browser#cancel`.

<a id="wait"></a>
### wait

#### Synopsis

`browser wait session navigation ?-timeout duration?`

#### Arguments and options

Pass the controller and its current navigation token.

#### Results

Returns a dictionary with `status`, `url` and `message`. `ready` means the target frame and loader reported document load, or Chromium accepted a same-document navigation. Other statuses are `timeout`, `cancelled` and `failed`. `url` is the requested URL. A failed navigation may include a browser reason in `message`.

#### Errors

`notfound` identifies an expired or unrelated navigation. `closed` identifies a released controller. `badvalue` identifies an invalid duration.

#### Lifetime and timeouts

The default deadline is 30 seconds. Tcl processes events during the wait. A timed-out navigation remains pending and may be waited on or cancelled.

#### Examples

```tcl
set result [browser wait $session $nav -timeout 5s]
```

#### Constraints

The application determines when any subsequent site-specific work is complete. HTTP responses such as a 404 can still load as documents.

#### See also

`machteld/command/browser#navigate`, `machteld/command/browser#cancel`.

<a id="cancel"></a>
### cancel

#### Synopsis

`browser cancel session navigation`

#### Arguments and options

Pass the currently selected navigation token.

#### Results

Returns the navigation result dictionary. A pending navigation becomes `cancelled`. A completed navigation retains its terminal status.

#### Errors

`notfound` identifies an expired navigation token. `closed` identifies an expired session.

#### Lifetime and timeouts

An active wait wakes when cancellation is requested.

#### Examples

```tcl
set result [browser cancel $session $nav]
```

#### Constraints

Cancellation stops loading in the selected tab. Requests already received by a server may have taken effect.

#### See also

`machteld/command/browser#wait`, `machteld/command/browser#navigate`.

<a id="release"></a>
### release

#### Synopsis

`browser release session`

#### Arguments and options

Pass the controller held by this interpreter.

#### Results

Returns the empty string. The persistent browser profile retains the session receipt.

#### Errors

`closed` identifies an expired or unknown controller.

#### Lifetime and timeouts

Closes the control connection, releases the profile lock and expires the token. The browser continues running. Ending the controller process also releases its lock and connection.

#### Examples

```tcl
browser release $session
```

#### Constraints

Use this operation when another run of the application should resume the same tab.

#### See also

`machteld/command/browser#attach`, `machteld/command/browser#close`.

<a id="close"></a>
### close

#### Synopsis

`browser close session ?-timeout duration?`

#### Arguments and options

Pass the controller and optionally specify how long to wait for browser exit.

#### Results

Returns the empty string after the recorded browser process exits, then releases the controller. Profile data stays on disk.

#### Errors

`timeout` means exit was still pending at the deadline. `closed` identifies an expired controller or lost connection.

#### Lifetime and timeouts

The default is 10 seconds. The call processes Tcl events. A timeout retains the controller for a retry or explicit release.

#### Examples

```tcl
browser close $session -timeout 15s
```

#### Constraints

The browser receives its normal orderly exit request. Management policy and desktop prompts can affect when exit completes.

#### See also

`machteld/command/browser#release`, `machteld/command/browser#attach`.
