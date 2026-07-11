# machteld/Tcl — serious-task reference

Write an ordinary Tcl 9 script executed by machteld. Every task in this corpus
takes integers and returns one integer. Use the exact procedure name shown in
`task.md` and accept the stated number of positional arguments.

## Submission contract

Define the requested procedure in `solution.tcl`. Helper procedures are allowed.
Do not prompt, read stdin, print a result, or run task work while the file is
being loaded. The checker sources the file and calls the procedure directly.

```tcl
proc square {n} {
    return [expr {$n * $n}]
}
```

Run `check.cmd` to evaluate the visible examples. Each case is evaluated in a
fresh machteld process, so do not rely on state left by another case.

## Tcl syntax

Commands are words separated by whitespace and ended by a newline or semicolon.
The first word is the command name. `$name` substitutes a variable and
`[command ...]` substitutes a nested command's result. Braces group text without
substitution; use them for procedure and control-flow bodies and for `expr`.
Double quotes form one word while allowing substitutions.

```tcl
set x 4
set y [expr {$x + 1}]
```

Variables are created with `set`; `incr name` adds one. Decisions and loops are
ordinary commands:

```tcl
if {$x < 0} {
    set x [expr {-$x}]
} elseif {$x == 0} {
    set x 1
}

set i 0
while {$i < 10} {
    incr i
}

for {set i 0} {$i < 10} {incr i} {
    # body
}
```

`break` and `continue` work inside loops. A procedure returns its final command
result implicitly, but an explicit `return $value` is clearer.

## Integer and remainder conventions

Tcl integers grow beyond 64 bits. Preserve the task's stated signed-64-bit input
interpretation, but do not clip intermediate values unless the task explicitly
requires a fixed-width bit pattern.

Arithmetic and comparisons belong in `expr {...}`. Operators include
`+ - * / %`, `< <= == != >= >`, `&& || !`, and the bit operators
`& | ^ ~ << >>`. With integer operands, `/` is integer floor division and `%`
has the divisor's sign. `>>` is arithmetic (sign-extending) on negative values.

Some tasks explicitly require division truncated toward zero or a remainder
with the dividend's sign. These general helpers implement that contract without
using floating point:

```tcl
proc tdiv {a b} {
    set q [expr {abs($a) / abs($b)}]
    return [expr {(($a < 0) != ($b < 0)) ? -$q : $q}]
}

proc trem {a b} {
    set q [tdiv $a $b]
    return [expr {$a - $q * $b}]
}
```

Normalize a remainder to `[0,m)` for positive `m` with:

```tcl
proc modnorm {a m} {
    return [expr {(($a % $m) + $m) % $m}]
}
```

For a logical right shift of a raw 64-bit two's-complement pattern, mask before
the arithmetic shift:

```tcl
proc u64 {x} {
    return [expr {$x & 0xffffffffffffffff}]
}

proc lsr64 {x n} {
    return [expr {($x & 0xffffffffffffffff) >> $n}]
}
```

Use the task's narrower mask when it specifies a width below 64 bits.

## Lists and common operations

Tcl lists are values, not comma-delimited syntax. Build one with `list` or
braces, append through a variable with `lappend`, and index with `lindex`.
Nested indices may be supplied together.

```tcl
set values {3 5 7}
lappend values 9
set first [lindex $values 0]
set cell [lindex $table $row $column]

foreach value $values {
    # body
}
```

Useful expression functions include `abs`, `min`, and `max`. All Tcl 9 core
commands are available. Do not assume Tcllib or another optional package.

## Solving a task

1. Read all of `task.md`, including its boundary and sign conventions.
2. Define the exact requested procedure in `solution.tcl`.
3. Run `check.cmd` and repair any visible mismatch.
4. Stop after it passes, leaving the final solution file in place.

