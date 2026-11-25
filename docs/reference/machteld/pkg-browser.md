---
id: machteld/package/browser
type: package
title: Controlling an application browser session
summary: Launch, attach to, navigate and close an application-owned Edge or Chromium profile.
commands: machteld::browser, package require machteld::browser, ::machteld::browser
---

# Controlling an application browser session

## Usage

The public `browser` command loads `machteld::browser 1.0` on first use. A program may also load it with `package require machteld::browser 1.0`. Use `::machteld::browser` from a nested namespace.

| Call | Result |
| --- | --- |
| `browser launch -profile dir ?-executable path? ?-headless boolean? ?-timeout duration?` | Starts an installed browser for the application's profile and returns a controller token. |
| `browser attach -profile dir ?-timeout duration?` | Resumes control of a running browser from its recorded profile. |
| `browser navigate session url` | Starts one page navigation and returns its navigation token. |
| `browser wait session navigation ?-timeout duration?` | Returns `status`, `url` and `message`. Ready, failed, cancelled and timeout outcomes are distinguished. |
| `browser cancel session navigation` | Cancels that navigation and returns its outcome. |
| `browser release session` | Releases control and leaves the browser open for a later attach. |
| `browser close session ?-timeout duration?` | Requests browser exit and keeps the profile on disk. |

## Errors and lifetime

One interpreter owns each controller and its navigation tokens. One controller holds a profile at a time. `MACHTELD BROWSER busy` signals contention, `ownership` signals a profile or identity mismatch, and `closed` signals an expired session. A close timeout retains the controller. A caller can retry or release it. Site-specific sign-in and page behavior belong to the application.

## Example

```tcl
set session [browser launch -profile [file join $appData browser]]
try {
    set navigation [browser navigate $session $url]
    puts [dict get [browser wait $session $navigation -timeout 30s] status]
} finally {browser release $session}
```

Retrieve `machteld/command/browser` for duration defaults, accepted URL schemes and errors for each operation.
