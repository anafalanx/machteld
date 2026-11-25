---
id: machteld/package/job
type: package
title: Supervised background jobs
summary: Run a supervised record-producing child while the Tcl or Tk event loop remains responsive.
commands: machteld::job, ::machteld::job::Job, job snapshot, job cancel, machteld::job::Job
---

# Supervised background jobs

## Usage

`package require machteld::job 1.0` provides `::machteld::job::Job new ?onEventPrefix?`. Each object owns one child at a time. Use it for a child that writes complete UTF-8 records to stdout, one per line, and diagnostics to stderr.

| Object method | Effect |
| --- | --- |
| `$job start argv ?-timeout duration? ?-mem size? ?-window mode? ?-console mode?` | Launch a list of executable and argument words with closed stdin. Defaults are `30s` and `128M`. The window and console choices follow `child start`. Returns 1 for an attempted start and 0 when already running or closed. |
| `$job snapshot` | Returns `phase`, `result`, `error` and `log`. Phases are `idle`, `running`, `done`, `error`, `canceled` and `closed`. The log retains the latest 8,192 stderr characters. A completed process supplies the `child` result dictionary. |
| `$job cancel` | Cancels a running child, emits `finished` and returns 1. Otherwise returns 0. |
| `$job close` | Releases the child, event registrations and timers, clears the callback and sets `phase closed`. |
| `$job destroy` | Releases the resources and deletes the TclOO command. |

## Events and errors

The callback receives `job event data`. `started` carries an empty value, `lines` carries a list of decoded records, `stderr` carries diagnostic text, and `finished` carries the state dictionary. Service the Tcl event loop. Each batch holds up to 32 lines. A record may contain up to 65,536 bytes before LF. Invalid UTF-8, an oversized or unterminated final record, a callback exception or a nonzero child exit sets the error state. A failed launch can report `finished` before `start` returns. Errors parsing the argument list or option names are immediate Tcl errors. A finished job can start another child until closed.

## Example

```tcl
package require machteld::job
proc report {job event data} {
    if {$event eq "lines"} {foreach line $data {puts $line}}
    if {$event eq "finished"} {set ::jobResult $data}
}
set job [::machteld::job::Job new report]
try {
    $job start [list {*}[app launch] --list-records] -timeout 20s
    if {[dict get [$job snapshot] phase] eq "running"} {vwait ::jobResult}
    puts [dict get [$job snapshot] phase]
} finally {$job destroy}
```

The application implements `--list-records` and chooses its record format. See `machteld/command/child#start` and `machteld/command/app#launch`.
