# machteld/Tcl scripting reference

Write an ordinary Tcl 9 script executed by machteld 0.2.1. Define the exact
global procedure named in `task.md`; do not read stdin, print the answer, or do
task work while the file is sourced. The checker calls the procedure directly
and evaluates every example in a fresh process.

```tcl
proc summarize {items} {
    return [join $items ","]
}
```

Commands are words separated by whitespace. `$name` substitutes a variable,
`[command ...]` substitutes a nested command result, braces group text without
immediate substitution, and double quotes form one word with substitution.

## Control flow, lists, and strings

```tcl
set out {}
foreach item $items {
    if {$item ne ""} {
        lappend out $item
    }
}
set first [lindex $out 0]
set n [llength $out]
set text [join $out "\n"]
```

`eq` and `ne` compare strings. Numeric comparisons and arithmetic use
`expr {...}`. `for`, `while`, `break`, and `continue` are available. Useful
list operations include `list`, `lappend`, `lindex`, `llength`, `lset`,
`lreplace`, `lreverse`, and `lassign`.

Strings are exact Tcl values. `string length`, `string index`, and
`string range` inspect them. To split on the ASCII space character only and
drop empty fields (without treating tabs or newlines as separators):

```tcl
set fields {}
foreach field [split $text " "] {
    if {$field ne ""} { lappend fields $field }
}
```

## Dictionaries

A Tcl dictionary is a key/value value. The forms below mutate the variable
named `mapping`:

```tcl
set mapping [dict create]
dict set mapping $key $value
if {[dict exists $mapping $key]} {
    set value [dict get $mapping $key]
    dict unset mapping $key
}
dict for {key value} $mapping {
    # inspect each pair
}
```

Lists can contain other lists or dictionaries. This is often convenient for a
stack: `lappend stack $value`, `lindex $stack end`, and
`set stack [lreplace $stack end end]` push, read, and pop.

## Validation and errors

`regexp` returns true on a match. Use `-indices` when you need to prove that a
match covers the entire string rather than a prefix:

```tcl
if {[regexp -indices {^[+-]?[0-9]+} $token span]} {
    lassign $span first last
    set whole [expr {$first == 0 && $last == [string length $token] - 1}]
}
```

Raise an error with `error "message"`. An uncaught error from the requested
procedure is how a fallible case is reported to the checker.

Tcl integers have arbitrary precision. If a task specifies a signed-64-bit
range, validate the result explicitly against `-9223372036854775808` and
`9223372036854775807`; do not rely on overflow. `scan $character %c code`
returns a character's integer code when manual ASCII processing is useful.

Read all of `task.md`, edit only `solution.tcl`, and use `check.cmd` for the
visible examples. Stop after it passes or after leaving your best attempt.
