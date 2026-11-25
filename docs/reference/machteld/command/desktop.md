---
id: machteld/command/desktop
type: command
title: desktop
summary: List and activate desktop windows and open a local document.
commands: desktop, desktop windows, desktop activate, desktop open
---

# desktop

## Synopsis

`desktop windows`

`desktop activate token`

`desktop open path`

## Arguments and options

Choose a window token from the list, or supply a local document path.

## Results

Window queries return a Tcl list of dictionaries. Activation returns two boolean fields. Opening a document returns an empty string when Windows accepts the request.

## Errors

Errors use `MACHTELD DESKTOP` and a code described under each operation.

## Lifetime and timeouts

Window selection belongs to the interpreter. Opening a document uses the current user's Windows file associations.

## Examples

```tcl
foreach window [desktop windows] {
    puts [list [dict get $window title] [dict get $window token]]
}
```

## Constraints

Windows controls foreground eligibility and the associated viewer. Applications own their search, ranking and presentation.

## See also

`machteld/command/child#present`, `machteld/command/manifest`.

<a id="windows"></a>
### windows

#### Synopsis

`desktop windows`

#### Arguments and options

Takes no arguments.

#### Results

Each dictionary has `token`, `title`, `class`, `pid`, `minimized` and `foreground`. Order follows desktop window enumeration. Duplicate titles are separate records. A protected window may have an empty token.

#### Errors

`usage` for extra arguments or `oserror` when Windows cannot enumerate the desktop.

#### Lifetime and timeouts

A token continues to identify its window across queries in this interpreter. Closing the window or removing it from the list expires its token. Interpreter deletion clears the selections.

#### Examples

```tcl
set available [lmap row [desktop windows] {
    if {[dict get $row token] eq {}} continue
    list [dict get $row title] [dict get $row token]
}]
```

#### Constraints

Lists visible ordinary top-level application windows on this thread's desktop, including minimized windows. Tool, cloaked and no-activate windows are omitted. Titles come from the window manager's stored captions.

#### See also

`machteld/command/desktop#activate`, `machteld/command/child#present`.

<a id="activate"></a>
### activate

#### Synopsis

`desktop activate token`

#### Arguments and options

Pass a nonempty `token` returned by `desktop windows` in this interpreter.

#### Results

`requested` records whether Windows accepted the foreground request. `foreground` records whether the target was the foreground window when checked immediately afterward.

#### Errors

`notfound` identifies an invalid, closed or replaced selection. `usage` indicates the wrong number of arguments.

#### Lifetime and timeouts

A minimized window receives an asynchronous restore request. Read `desktop windows` again to observe later changes.

#### Examples

```tcl
if {[dict get $row token] ne {}} {
    set result [desktop activate [dict get $row token]]
    puts [dict get $result foreground]
}
```

#### Constraints

Windows may decline foreground activation based on recent user input. Activation preserves the user's foreground rules and checks the target's identity before making the request.

#### See also

`machteld/command/desktop#windows`.

<a id="open"></a>
### open

#### Synopsis

`desktop open path`

#### Arguments and options

Pass an existing regular file on a local drive. A relative path resolves against the current working directory.

#### Results

An empty string means Windows accepted the open request.

#### Errors

`notfound` indicates a missing file, `badvalue` an invalid local path or a directory, `noassociation` a file type Windows cannot open, and `oserror` another Windows failure.

#### Lifetime and timeouts

The command waits for shell dispatch. The viewer owns the document after dispatch and can reuse an existing process.

#### Examples

```tcl
desktop open [file join [pwd] {meeting notes.pdf}]
```

#### Constraints

The shell receives the complete path as one file argument. The user's account selects the viewer. This operation opens existing local documents, including paths with spaces.

#### See also

`machteld/command/canon`, `machteld/command/run`.
