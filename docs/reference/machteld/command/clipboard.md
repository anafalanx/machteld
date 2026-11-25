---
id: machteld/command/clipboard
type: command
title: ::machteld::clipboard
summary: Check whether this process owns the Windows clipboard.
commands: clipboard, clipboard owned
---

# ::machteld::clipboard

## Synopsis

```tcl
::machteld::clipboard owned
```

## Arguments and options

Pass the single operation `owned`. Use the fully qualified command name.

## Results

Returns a boolean. Ownership belongs to the process whose window Windows
identifies as the clipboard owner.

## Errors

An invalid operation or argument count raises `MACHTELD CLIPBOARD usage`.

## Lifetime and timeouts

The query is synchronous and does not open the clipboard or require Tk.

## Examples

```tcl
set thisProcessOwnsClipboard [::machteld::clipboard owned]
```

## Constraints

The answer describes ownership at the time of the query. Another application
can take ownership immediately afterward. Use Tk's `::clipboard` for clipboard
data.

## Subcommands

<a id="owned"></a>
### owned

#### Synopsis

`::machteld::clipboard owned`

#### Arguments and options

Takes no arguments or options.

#### Results

Returns `1` when the owner window belongs to the calling process, including
a window created by another interpreter in that process. Returns `0` for
another process, an absent owner window, or an owner window that disappeared
before its process could be identified.

#### Errors

Extra arguments raise `MACHTELD CLIPBOARD usage`.

#### Lifetime and timeouts

Returns immediately without acquiring a clipboard lock, reading any formats,
or changing the contents.

#### Examples

```tcl
package require Tk
if {[::machteld::clipboard owned]} {
    puts "This application owns the clipboard."
}
```

#### Constraints

Ownership alone cannot identify the text, image, or other data on the
clipboard, and does not guarantee future access.

#### See also

`tk/command/clipboard`.

## See also

`tk/command/clipboard`, `machteld/command/manifest`.
