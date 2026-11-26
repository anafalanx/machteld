---
type: guide
title: Runnable agent recipes
description: Four complete Tcl programs for a worker, a headless child, an application archive and a verified SQLite backup.
tags: [machteld, agent, worker, child, packaging, sqlite]
---

# Runnable agent recipes

Each section contains a complete program. Save its Tcl block as a UTF-8 file and pass its path to `machteld.exe`. Each program creates and cleans its own temporary directory.

## Generate a worker

The generated script opts into the host itself. Its standard output carries the worker protocol. The parent prints the reply's result, `42`.

```tcl
package require machteld 30-
set work [file tempdir]
try {
    set script [file join $work worker.tcl]
    publish bytes $script {package require machteld 30-
worker on double {value} {expr {2 * $value}}
worker serve}
    set pool [pool create -width 1 -timeout 30s -- [info nameofexecutable] $script]
    try {
        pool submit $pool [list [dict create op double value 21]]
        set reply [lindex [pool wait $pool -timeout 30s] 0]
        if {![dict get $reply ok]} {error "worker failed: $reply"}
        puts [dict get $reply result]
    } finally {pool close $pool}
} finally {file delete -force -- $work}
```

## Run a headless child

Pass each argument as a separate Tcl value. The child echoes the argument containing spaces. The parent captures stdout, checks the exit status and closes its handle.

```tcl
package require machteld 30-
set work [file tempdir]
try {
    set script [file join $work echo.tcl]
    publish bytes $script {package require machteld 30-
puts [lindex $argv 0]}
    set token [child start -console none -timeout 30s -- [info nameofexecutable] $script {two words}]
    try {
        set result [child wait $token]
        if {[dict get $result status] ne "ok"} {error "child failed: $result"}
        puts [string trimright [encoding convertfrom utf-8 [dict get $result out]] \r\n]
    } finally {child close $token}
} finally {file delete -force -- $work}
```

## Package an application

This project lists its entry point explicitly. Both packaging and running the resulting archive use the same executable. A successful run prints `from the archive`.

```tcl
package require machteld 30-
set work [file tempdir]
try {
    publish bytes [file join $work main.tcl] {package require machteld 30-
puts "from the archive"}
    set manifest [file join $work app.dict]
    publish bytes $manifest [dict create schema 1 entry main.tcl files {main.tcl}]
    set archive [file join $work demo.machteld]
    set host [info nameofexecutable]
    set packed [run -timeout 60s -- $host pack $manifest -o $archive]
    if {[dict get $packed status] ne "ok"} {error "pack failed: $packed"}
    set result [run -timeout 30s -- $host $archive]
    if {[dict get $result status] ne "ok"} {error "archive failed: $result"}
    puts [string trimright [encoding convertfrom utf-8 [dict get $result out]] \r\n]
} finally {file delete -force -- $work}
```

## Back up SQLite

The backup helper verifies the copy and publishes it to a new path. This example closes the source, reopens the snapshot read-only and prints its saved value, `Bruxelles`.

```tcl
package require machteld 30-
package require machteld::sqlite
set work [file tempdir]
try {
    set snapshot [file join $work snapshot.db]
    sqlite3 db [file join $work source.db]
    try {
        db eval {CREATE TABLE station(name TEXT); INSERT INTO station VALUES ('Bruxelles')}
        ::machteld::sqlite::backup db $snapshot
    } finally {db close}
    sqlite3 saved $snapshot -readonly 1 -create 0
    try {puts [saved onecolumn {SELECT name FROM station}]} finally {saved close}
} finally {file delete -force -- $work}
```
