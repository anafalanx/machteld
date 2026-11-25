---
id: machteld/command/desktop
type: command
title: desktop
summary: Select windows and installed applications, open documents and receive Explorer file drops in Tk.
commands: desktop, desktop windows, desktop activate, desktop open, desktop apps, desktop launch, desktop icon, desktop drop
---

# desktop

## Synopsis

`desktop windows`

`desktop activate token`

`desktop open path`

`desktop apps`

`desktop launch target`

`desktop icon target photo ?size?`

`desktop drop widget ?commandPrefix?`

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

<a id="apps"></a>
### apps

#### Synopsis

`desktop apps`

#### Arguments and options

Takes no arguments. Resolves both the user and shared Start menus and the Windows AppsFolder.

#### Results

Each row contains `name`, `kind`, `source`, and `target`. The kind is `shortcut` or `store`. Source is the shortcut path or package application user model ID. Pass the target to `desktop launch` or `desktop icon`.

#### Errors

`oserror` reports a Windows catalog failure.

#### Lifetime and timeouts

Each call reads the current inventory. A successful refresh expires removed entries. Unchanged entries preserve their tokens. A failed refresh retains the preceding inventory.

#### Examples

```tcl
set entries [desktop apps]
foreach entry $entries {
    puts [list [dict get $entry kind] [dict get $entry name]]
}
```

#### Constraints

The list includes closed applications. Start-menu traversal skips reparse points and inaccessible directories. Icons load on demand. Your application chooses ordering and duplicate-name presentation.

#### See also

`machteld/command/desktop#launch`, `machteld/command/desktop#icon`.


<a id="launch"></a>
### launch

#### Synopsis

`desktop launch target`

#### Arguments and options

Pass the `target` from a `desktop apps` result in this interpreter.

#### Results

Returns an empty string when Windows accepts the launch.

#### Errors

`notfound` indicates an expired selection or a deleted or changed shortcut. `oserror` reports a Windows activation failure.

#### Lifetime and timeouts

The shell can reuse an existing program. A shortcut launches with its own recorded arguments and working directory.

#### Examples

```tcl
set selected [lindex $entries $selectedRow]
desktop launch [dict get $selected target]
```

#### Constraints

Windows handles Store activation using the selected application user model ID. The call preserves the user's foreground policy.

#### See also

`machteld/command/desktop#apps`, `machteld/command/desktop#open`.


<a id="icon"></a>
### icon

#### Synopsis

`desktop icon target photo ?size?`

#### Arguments and options

Pass an application `target`, the name of an existing Tk photo image and an optional size in pixels from 8 through 256. The default is 32.

#### Results

Returns the supplied photo name after replacing its pixels with the Shell icon. Tk receives straight alpha and the Shell's actual image dimensions.

#### Errors

`badvalue` indicates a missing Tk photo or invalid size. `notfound` identifies an expired selection. `oserror` reports a Shell extraction or bitmap error.

#### Lifetime and timeouts

The command obtains the image on demand. The caller owns the photo and can keep or delete it.

#### Examples

```tcl
package require Tk
set photo [image create photo]
desktop icon [dict get $selected target] $photo 32
label .applicationIcon -image $photo
```

#### Constraints

Run this on the thread that owns the Tk image. Headless applications can use `desktop apps` and `desktop launch` independently.

#### See also

`machteld/command/desktop#apps`, `tk/command/photo`.

<a id="drop"></a>
### drop

#### Synopsis

`desktop drop widget ?commandPrefix?`

#### Arguments and options

Load Tk and pass a widget path from this interpreter. A nonempty Tcl command prefix registers the widget. An empty list unregisters it. Omit the prefix to query the registration.

#### Results

A query returns the current prefix, or the empty list for a widget with no registration. A change returns the empty string. When Explorer drops files, Machteld appends one argument to the prefix and calls it. That argument is the ordered Tcl list of Windows paths, including any spaces and Unicode characters.

#### Errors

`notfound` identifies a missing widget or unloaded Tk. `badvalue` identifies an invalid widget path or malformed command prefix. Windows registration failures use `oserror`. A path conversion error or callback exception reaches the interpreter's background error handler.

#### Lifetime and timeouts

Machteld queues the drop on the owning interpreter's event loop. Destroying the widget, replacing or removing its callback, or deleting the interpreter discards undelivered drops. A recreated widget starts with an empty registration. The callback can destroy its own widget.

#### Examples

```tcl
package require Tk
text .files
pack .files -fill both -expand 1
proc showFiles {widget paths} {
    foreach path $paths { $widget insert end "$path\n" }
}
desktop drop .files [list showFiles .files]
```

#### Constraints

Register each widget surface that should accept file drops. A Tk child receives drops over its own Windows window. The application decides which reported paths it will open.

#### See also

`machteld/command/desktop#open`, `tk/command/winfo`.
