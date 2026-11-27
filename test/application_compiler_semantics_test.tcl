package require machteld

lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] \
    packages application-compiler]
package require application-compiler 0.1

namespace eval ::semanticsTest {variable count 0}
proc ::semanticsTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::semanticsTest::check {source expected label} {
    set diagnostics [::appcompiler::check [dict create sample $source]]
    equal [lsort [lmap d $diagnostics {dict get $d code}]] [lsort $expected] $label
}

namespace eval ::semanticsTest {
    set convert {export fn .read($args: list<text>) -> result<text,text> {
    return match $args {
        ['--value', $s] => ok($s)
        _ => err('missing')
    }
}
export fn .copy($args: list<text>) -> result<text,text> {
    return ok(.read($args)?)
}}
    set compare {export record .item {
    id: text
    marks: list<int?>
}
export choice .event {
    empty
    set(.item)
}
export fn .same($a: .event, $b: .event) -> bool { return $a == $b }}
    set project [dict create convert $convert compare $compare]
    equal [::appcompiler::check $project] {} "result arms and nested comparable types"
    set compiled [::appcompiler::compile $project ::semanticsApp]
    namespace eval :: [dict get $compiled script]

    equal [::semanticsApp::convert::copy [list --value {}]] [list ok {}] "present empty argument"
    equal [::semanticsApp::convert::copy [list --value]] {err missing} "propagation preserves a text error"
    check [string map {result<text,text> result<int,text>} $convert] RETURN_TYPE \
        "the joined success type must match the declaration"
    check {fn .x() -> result<bytes,text> { return ok(read_stdin_bytes()?) }} PROPAGATION_TYPE \
        "propagation preserves the declared error type"
    check {fn .x() -> bool { return read_stdin_bytes()? }} PROPAGATION_TYPE \
        "a plain return type cannot propagate a result"

    set marks [list none [list some 2]]
    set left [list set [dict create id 007 marks $marks]]
    set right [list set [dict create marks $marks id 007]]
    equal [::semanticsApp::compare::same $left $right] 1 "record equality ignores dictionary key order"
    equal [::semanticsApp::compare::same $left [list set [dict create id 7 marks $marks]]] 0 \
        "record equality preserves the spelling of text"
    equal [::semanticsApp::compare::same $left empty] 0 "choice tags participate in equality"
    check {record .node { children: list<.node> }
fn .x($a: .node, $b: .node) -> bool { return $a != $b }} {} "recursive comparable type"
    check {choice .event { payload(problem) }
record .box { events: list<.event?> }
fn .x($a: .box) -> bool { return $a == $a }} NOT_COMPARABLE \
        "unsupported equality propagates through a choice, optional, list and record"
    check {record .a { value: int }
record .b { value: int }
fn .x($a: .a, $b: .b) -> bool { return $a == $b }} OPERAND_TYPE \
        "same-shaped records cannot be compared across nominal types"

    check {fn .x($xs: list<text>) -> bool { return match $xs { [] => false } }} MATCH_NONEXHAUSTIVE \
        "one list length does not cover all possible lists"
    check {fn .x($xs: list<int>) -> bool {
    return match $xs {
        ['1'] => true
        _ => false
    }
}} PATTERN_TYPE "a text pattern cannot match an integer"
    check {fn .x($valid: bool) -> int {
    if $valid { return 1 } else { return 2 }
}} {} "both branches return"
    check {fn .x($valid: bool) -> int {
    if $valid { return 1 }
}} MISSING_RETURN "one branch can reach the end of a value function"
    check {fn .x() -> int {
    read_stdin_bytes()
    if 1 { return 2 }
}
fn .other() -> text { return $missing + 1 }} \
        {DISCARDED_RESULT CONDITION_TYPE MISSING_RETURN UNKNOWN_BINDING} \
        "accumulate independent errors without a return-type cascade"

    set source {fn .read($in: text) -> result<text,problem> { return decode_json<.missing>($in) }}
    set diagnostics [::appcompiler::check [dict create model $source]]
    equal [lmap d $diagnostics {dict get $d code}] UNKNOWN_TYPE "missing JSON schema"
    set location [dict get [lindex $diagnostics 0] node]
    set first [expr {[dict get $location column] - 1}]
    set last [expr {[dict get $location endColumn] - 2}]
    equal [list [dict get $location module] [dict get $location line] [string range $source $first $last]] \
        {model 1 .missing} "diagnostic marks the exact JSON type argument"
    puts "application compiler semantics: $count assertions passed"
}
