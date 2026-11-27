package require machteld
lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] \
    packages application-compiler]
package require application-compiler 0.1

namespace eval ::iterationTest {variable count 0}
proc ::iterationTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::iterationTest::call {app fn args} {
    $app eval [list ::iterationApp::walk::$fn {*}$args]
}
proc ::iterationTest::mark {name args} {
    variable calls
    lappend calls $name
}
proc ::iterationTest::lineOf {source fragment} {
    set n 0
    foreach line [split $source \n] {
        incr n
        if {[string trim $line] eq $fragment} {return $n}
    }
    error "missing source fragment: $fragment"
}

proc ::iterationTest::direct {sources} {
    variable calls
    equal [::appcompiler::check $sources] {} "iteration source checks"
    set compiled [::appcompiler::compile $sources ::iterationApp]
    set app [interp create]
    try {
        interp limit $app time -seconds [expr {[clock seconds] + 20}]
        $app eval [dict get $compiled script]
        $app alias mark ::iterationTest::mark
        foreach fn {lower upper iterable} {
            $app eval [list trace add execution ::iterationApp::walk::$fn enter [list mark $fn]]
        }
        set calls {}
        equal [call $app sum 2 5] 14 "closed range visits both ends"
        equal $calls {lower upper iterable} "endpoints and iterable evaluated once in source order"
        equal [call $app half 4 -2] {4 -2 0} "descending half-open descriptor"
        equal [call $app closed -2 -2] {-2 -2 1} "closed singleton descriptor"
        foreach {bounds count} {{3 3 0} 0 {3 3 1} 1 {5 1 0} 0 {5 1 1} 0 {-2 1 0} 3 {-2 1 1} 4} {
            equal [call $app count_range $bounds] $count "iterate external range $bounds"
        }
        set big 9999999999999999999999999999999999999999
        equal [call $app count_range [call $app half $big [expr {$big + 3}]]] 3 "bignum bounds"
        equal [call $app first [call $app half 0 $big]] 0 "break immediately across a bignum span"
        foreach malformed {{1 2} {1 wrong 1} {1 2 2}} {
            equal [catch {call $app count_range $malformed}] 1 "reject malformed external range $malformed"
        }
        equal [call $app nested] 138138 "innermost and labeled break and continue select their targets"
        equal [call $app siblings] 5 "sequential loops reuse labels and iterator names"
        equal [call $app snapshot {4 5} {8 9}] 12345 "mutating inputs in the loop keeps its initial bounds and items"
        equal [call $app break [dict create in 17]] 17 "loop keywords as field and function names"
        equal [call $app keyword] continue "import for, .for::break() and .choice::continue"
        equal [call $app keyword_while [dict create while true]] 1 "while stays valid as a module, function, field and variant name"
        $app eval {trace add execution ::iterationApp::walk::while enter {mark condition}}
        set calls {}
        equal [call $app recheck 0] 13 "continue reevaluates a dotted boolean function against changed state"
        equal $calls {condition condition condition condition} "one condition call per pass and one final false call"
        set calls {}
        equal [call $app recheck 3] 0 "initial false condition skips the body"
        equal $calls condition "initial false condition runs once"
        equal [call $app while_outer] 138138 "for continues and breaks its labeled outer while"
        equal [call $app for_outer] 13 "while continues and breaks its colon-labeled outer for"
        equal [call $app condition_result 2] {ok 2} "a false propagated boolean ends the loop"
        lassign [call $app condition_result 1] tag problem
        set line [lineOf [dict get $sources walk] {$q ::= quotient(1, $n)?}]
        set origin [dict get $problem origin]
        equal [list $tag [dict get $problem code] [dict get $origin module] [dict get $origin line]] \
            [list err DIVIDE_BY_ZERO walk $line] "propagation on a later condition evaluation preserves its original source"

        set special {two words; [error BAD] $still_text}
        set labels [list {} 007 7 {} $special 雪]
        foreach {needle expected} [list {} 2 7 1 007 1 $special 1 雪 1 missing 0] {
            equal [call $app occurrences $labels $needle] $expected "list iteration preserves [list $needle]"
        }
        equal [call $app checked {3 -4 2}] {ok 7} "propagate succeeds across loop iterations"
        lassign [call $app checked {3 0 2}] tag problem
        equal [list $tag [dict get $problem code]] {err DIVIDE_BY_ZERO} "typed failure exits the loop"
        set origin [dict get $problem origin]
        set line [lineOf [dict get $sources walk] {$part ::= quotient(12, $i)?}]
        equal [list [dict get $origin module] [dict get $origin line]] [list walk $line] \
            "loop body failure identifies the original operation"
        set locations [dict get $compiled sourceMap ::iterationApp::walk::checked]
        set sourceLines [lmap loc [dict values $locations] {dict get $loc line}]
        equal [expr {$line in $sourceLines}] 1 "generated loop body maps to its source statement"
        equal [call $app pick [list skip $special later]] [list ok $special] "return from loop preserves text"
        equal [call $app pick {skip skip}] {ok empty} "fallthrough after exhausting iterable"
        lassign [call $app pick {skip reject unused}] tag problem
        equal [list $tag [dict get $problem message]] {err {rejected item}} "loop can return a typed failure"
    } finally {interp delete $app}
}

proc ::iterationTest::runnable {sources} {
    set artifact [::appcompiler::application $sources entry]
    set out [file tempfile path]
    try {
        try {
            chan configure $out -encoding utf-8 -translation lf
            puts -nonewline $out [dict get $artifact script]
        } finally {close $out}
        set special {two words; [error BAD] $still_text}
        set exe [info nameofexecutable]
        set run [::machteld::run -timeout 10s -- $exe $path skip $special trailing]
        equal [list [dict get $run exit] [dict get $run out] [dict get $run err]] [list 0 $special {}] \
            "runnable loop returns the same exact element as direct execution"
        set run [::machteld::run -timeout 10s -- $exe $path skip reject trailing]
        set line [lineOf [dict get $sources walk] {if $item == 'reject' { return err(problem('rejected item')) }}]
        equal [list [dict get $run exit] [dict get $run out]] {1 {}} "runnable loop exits on typed failure"
        equal [string match "walk:$line:*: rejected item" [string trimright [dict get $run err] "\r\n"]] 1 \
            "runnable failure remains at its source line inside the loop"
        set run [::machteld::run -timeout 10s -- $exe $path --while-ok]
        equal [list [dict get $run exit] [dict get $run out] [dict get $run err]] {0 done {}} \
            "runnable while checks the typed condition before entering"
        set run [::machteld::run -timeout 10s -- $exe $path --while-error]
        set line [lineOf [dict get $sources walk] {$q ::= quotient(1, $n)?}]
        equal [list [dict get $run exit] [dict get $run out]] {1 {}} "runnable exits on failed while condition"
        equal [string match "walk:$line:*: *zero*" [string trimright [dict get $run err] "\r\n"]] 1 \
            "runnable condition error identifies the originating helper line"
    } finally {file delete -- $path}
}

proc ::iterationTest::negative {} {
    foreach {code source} {
        FIXED_ASSIGNMENT {fn .x() -> unit {
    for $i in 1..3 { $i = 0 }
    return unit
}}
        DUPLICATE_BINDING {fn .x($i: int) -> unit {
    for $i in 1..3 {}
    return unit
}}
        UNKNOWN_BINDING {fn .x() -> int {
    for $i in 1..3 {}
    return $i
}}
        ITERABLE_TYPE {fn .x() -> unit {
    for $i in 'abc' {}
    return unit
}}
        OPERAND_TYPE {fn .x() -> unit {
    for $i in 1..=3.5 {}
    return unit
}}
        RANGE_ELEMENT_TYPE {fn .x($r: range<text>) -> unit { return unit }}
        DUPLICATE_LOOP_LABEL {fn .x() -> unit {
    for .outer $i in 1..3 { for .outer $j in 1..3 {} }
    return unit
}}
        UNKNOWN_LOOP_LABEL {fn .x() -> unit {
    for .outer $i in 1..3 { continue .other }
    return unit
}}
        UNKNOWN_LOOP_LABEL {fn .x() -> unit {
    for .previous $i in 1..3 {}
    for $j in 2..3 { break .previous }
    return unit
}}
        LOOP_CONTROL {fn .x() -> unit {
    break
    return unit
}}
        LOOP_CONTROL {fn .x() -> unit {
    continue
    return unit
}}
        MISSING_RETURN {fn .x($values: list<int>) -> int {
    for $i in $values { return $i }
}}
        CONDITION_TYPE {fn .x() -> unit { while 0 { break }
    return unit
}}
        CONDITION_TYPE {fn .x() -> unit { while 'true' { break }
    return unit
}}
        CONDITION_TYPE {fn .x($b: bool?) -> unit { while $b { break }
    return unit
}}
        MISSING_RETURN {fn .x($b: bool) -> int { while $b { return 7 } }}
        DUPLICATE_LOOP_LABEL {fn .x() -> unit {
    while .active: true { for .active $i in 0..1 { break } }
    return unit
}}
        UNKNOWN_LOOP_LABEL {fn .x() -> unit {
    while true { break .unknown }
    return unit
}}
    } {
        set errors [::appcompiler::check [dict create invalid $source]]
        equal [lmap d $errors {dict get $d code}] [list $code] "loop diagnostic $code"
    }
}

namespace eval ::iterationTest {
    set names {export choice .choice { continue }
export fn .break() -> .choice { return .choice::continue }}
    set legacy {export choice .state { while }
export fn .while() -> .state { return .state::while }}
    set walk {import for
import while
export record .holder { in: int }
export fn .break($record: .holder) -> int { return $record.in }
export fn .keyword() -> .for::choice { return .for::break() }
fn .lower($x: int) -> int { return $x }
fn .upper($x: int) -> int { return $x }
fn .iterable($r: range<int>) -> range<int> { return $r }
export fn .half($a: int, $b: int) -> range<int> { return $a..$b }
export fn .closed($a: int, $b: int) -> range<int> { return $a..=$b }
export fn .sum($a: int, $b: int) -> int {
    $sum := 0
    for $i in .iterable(.lower($a)..=.upper($b)) { $sum = $sum + $i }
    return $sum
}
export fn .count_range($r: range<int>) -> int {
    $n := 0
    for $i in $r { $n = $n + 1 }
    return $n
}
export fn .first($r: range<int>) -> int {
    $n := -1
    for $i in $r {
        $n = $i
        break
    }
    return $n
}
export fn .nested() -> int {
    $digits := 0
    for .outer $row in 1..=4 {
        for $col in 1..=4 {
            if $row == 2 { continue .outer }
            if $row == 4 { break .outer }
            if $col == 2 { continue }
            if $col == 4 { break }
            $digits = $digits * 10 + $col
        }
        $digits = $digits * 10 + 8
    }
    return $digits
}
export fn .siblings() -> int {
    $n := 0
    for .pass $i in 0..2 { $n = $n + $i }
    for .pass $i in 4..=4 { $n = $n + $i }
    return $n
}
export fn .snapshot($original: list<int>, $replacement: list<int>) -> int {
    $end := 4
    $items := $original
    $digits := 0
    for $i in 1..$end {
        $end = 1
        $digits = $digits * 10 + $i
    }
    for $item in $items {
        $items = $replacement
        $digits = $digits * 10 + $item
    }
    return $digits
}
export fn .occurrences($items: list<text>, $needle: text) -> int {
    $n := 0
    for $item in $items { if $item == $needle { $n = $n + 1 } }
    return $n
}
export fn .checked($items: list<int>) -> result<int,problem> {
    $sum := 0
    for $i in $items {
        $part ::= quotient(12, $i)?
        $sum = $sum + $part
    }
    return ok($sum)
}
export fn .pick($items: list<text>) -> result<text,problem> {
    for $item in $items {
        if $item == 'skip' { continue }
        if $item == 'reject' { return err(problem('rejected item')) }
        return ok($item)
    }
    return ok('empty')
}}
    append walk \n {export record .flags { while: bool }
export fn .keyword_while($f: .flags) -> bool {
    if $f.while { return .while::while() == .while::state::while }
    return false
}
fn .while($n: int) -> bool { return $n != 3 }
export fn .recheck($start: int) -> int {
    $n := $start
    $digits := 0
    while .while($n) {
        $n = $n + 1
        if $n == 2 { continue }
        $digits = $digits * 10 + $n
    }
    while false { return -1 }
    return $digits
}
export fn .while_outer() -> int {
    $n := 0
    $digits := 0
    while .outer: true {
        $n = $n + 1
        for $i in 1..=3 {
            if $n == 2 { continue .outer }
            if $n == 4 { break .outer }
            if $i == 2 { continue }
            $digits = $digits * 10 + $i
        }
        $digits = $digits * 10 + 8
    }
    return $digits
}
export fn .for_outer() -> int {
    $digits := 0
    for .outer: $i in 1..=4 {
        while true {
            if $i == 2 { continue .outer }
            if $i == 4 { break .outer }
            $digits = $digits * 10 + $i
            break
        }
    }
    return $digits
}
fn .enabled($n: int) -> result<bool,problem> {
    $q ::= quotient(1, $n)?
    return ok($q == 1)
}
export fn .condition_result($start: int) -> result<int,problem> {
    $n := $start
    while .enabled($n)? { $n = $n - 1 }
    return ok($n)
}}
    set entry {import walk
fn .main($args: list<text>) -> result<unit,problem> {
    $start ::= match $args {
        ['--while-ok'] => 2
        ['--while-error'] => 1
        _ => 0
    }
    if $start != 0 {
        $n ::= .walk::condition_result($start)?
        if $n == 2 { return write_stdout_utf8('done') }
        return err(problem('unexpected condition result'))
    }
    $chosen ::= .walk::pick($args)?
    return write_stdout_utf8($chosen)
}}
    set sources [dict create walk $walk entry $entry for $names while $legacy]
    direct $sources
    runnable $sources
    negative
    puts "application compiler iteration: $count assertions passed"
}
