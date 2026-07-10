# machteld/Tcl — compact reference

Write an ordinary Tcl 9 script executed by machteld. Tcl is command-oriented:
each command is words separated by whitespace and terminated by a newline or
semicolon. The first word names the command; the remaining words are arguments.

## Substitution and grouping

- `$name` substitutes a variable.
- `[command ...]` runs a nested command and substitutes its result.
- `{...}` groups text without substitution. Use braces for procedure bodies and
  `expr` expressions.
- `"..."` groups one word while still allowing `$` and `[...]` substitution.
- `#` starts a comment when it appears where a command could begin.

```tcl
set x 4
set y [expr {$x + 1}]
```

## Defining your solution

Define a global procedure with the **exact name** and arguments given by the
task. Return one result with `return`. For multiple outputs, return a Tcl list.
Signal a task-designated failure with `error`.

```tcl
proc square {n} {
    return [expr {$n * $n}]
}
```

The checker sources `solution.tcl`, calls the procedure directly, and converts
its Tcl result according to the task's expected integer or string type. Do not
prompt, read stdin, print results, or run work at file load time.

## Variables, arithmetic, and decisions

`set name value` assigns and `set name` reads. `incr name` increments an integer
variable. Put arithmetic and boolean expressions in `expr {...}`. With integer
operands, `/` performs integer division; `%` is remainder. Comparisons include
`< <= == != >= >`, and boolean operators include `&& || !`.

```tcl
if {$x < 0} {
    set x [expr {-$x}]
} elseif {$x == 0} {
    set x 1
} else {
    incr x
}
```

Loops use braced test and body arguments:

```tcl
foreach name $names {
    puts [string toupper $name]
}

set i 0
while {$i < 10} {
    incr i
}
```

Use `break` and `continue` inside loops.

All Tcl 9 core commands are available. Do not assume optional Tcllib packages.
The machteld command palette is loaded, but these pure-function pilot tasks do
not require it.

## Strings, lists, and dictionaries

Tcl values can be passed directly between string, list, and dictionary
commands. Common operations:

```tcl
string length $s
string index $s $i
string range $s $first $last
string first $needle $s
split $s ""                 ;# list of characters

llength $xs
lindex $xs $i
lappend xs $value
foreach x $xs { ... }

dict set d $key $value
dict get $d $key
dict exists $d $key
dict unset d $key
dict for {k v} $d { ... }
```

Lists are values, not comma-delimited syntax. Construct one with
`list $a $b`; expand its elements as separate command arguments with `{*}$xs`.

Within an `expr`, `in` tests membership in a list:

```tcl
if {$value in {red green blue}} { ... }
```

Tcl's `regexp` command returns whether a regular expression matches. `-all
-inline` returns all matching substrings. Tcl regular expressions support
anchors such as `^` and `$`, character classes such as `[0-9]`, repetition with
`+`/`*`, and whitespace/non-whitespace escapes `\s` and `\S`.

```tcl
regexp {^[A-Z][0-9]+$} $code
set words [regexp -all -inline {[A-Za-z]+} $text]
```

## Errors and diagnostics

Raise an error with `error "message"`. Use `try`/`trap` or `catch` only when the
task requires recovery. An uncaught Tcl error is correct for a case explicitly
marked as an expected failure. The provided checker displays Tcl's native error
message and stack trace.

## Solving a task

1. Define the requested procedure in `solution.tcl`.
2. Run `check.cmd`; it evaluates visible examples under machteld.
3. Iterate until it passes, then leave the final procedure in the file.
