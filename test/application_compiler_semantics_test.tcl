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

proc ::semanticsTest::expressionBodies {} {
    set model {export distinct .id = int
export fn .next($n: int) -> .id => make<.id>(.add($n, 1))
fn .add($a: int, $b: int) -> int => $a + $b
export fn .only($items: list<text>) -> text? =>
    match $items {
        [$name] => some($name)
        _ => none
    }
export fn .ratio($a: int, $b: int) -> result<int,problem> =>
    ok(
        quotient($a, $b)?
    )
export fn .exact($a: int, $b: int) -> result<decimal,problem> =>
    (
        $a / $b
    )
export fn .reject() -> result<int,problem> =>
    err(problem('no value'))}
    set client {import model
export fn .label($n: int) -> int => underlying(.model::next($n))
export fn .ratio($a: int, $b: int) -> result<int,problem> { return .model::ratio($a, $b) }
fn .finished() -> unit => unit
export fn .main($args: list<text>) -> result<unit,problem> => ok(.finished())}
    set sources [dict create client $client model $model]
    equal [::appcompiler::check $sources] {} "cross-module expression bodies check"
    set compiled [::appcompiler::compile $sources ::shortBodyApp]
    namespace eval :: [dict get $compiled script]
    equal [::shortBodyApp::client::label 009] 10 "forward call and imported distinct result"
    equal [::shortBodyApp::model::only [list {}]] [list some {}] "expression match retains a present empty value"
    equal [::shortBodyApp::model::only {a b}] none "expression match returns an absent value"
    equal [::shortBodyApp::client::main {}] [list ok {}] "expression body returns unit through an entry"
    set app [::appcompiler::application $sources client]
    equal [dict exists $app sourceMap ::application::client::main] 1 "application accepts the expression-bodied entry"
    equal [::shortBodyApp::client::ratio -8 3] {ok -2} "multiline call inside an expression body"

    foreach {fn args token text} [list ratio {1 0} ? {        quotient($a, $b)?} exact {1 3} ( {    (} \
            reject {} err {    err(problem('no value'))}] {
        lassign [::shortBodyApp::model::$fn {*}$args] tag problem
        equal $tag err "$fn returned a typed failure"
        set origin [dict get $problem origin]
        set line [expr {1 + [lsearch -exact [split $model \n] $text]}]
        set column [expr {1 + [string first $token $text]}]
        equal [list [dict get $origin module] [dict get $origin line] [dict get $origin column]] \
            [list model $line $column] "$fn preserves the expression's original position"
    }
    set returnSites [dict values [dict get $compiled sourceMap ::shortBodyApp::model::exact]]
    set firstLine [expr {1 + [lsearch -exact [split $model \n] {    (}]}]
    equal [lindex $returnSites end] [dict create module model line $firstLine column 5] \
        "generated return maps to the opening expression even when the operator starts on a different line"

    set wrong {fn .bad() -> int =>
    'wrong'}
    set diagnostics [::appcompiler::check [dict create sample $wrong]]
    equal [lmap item $diagnostics {dict get $item code}] RETURN_TYPE "single expression must match the declared return"
    set where [dict get [lindex $diagnostics 0] node]
    equal [list [dict get $where line] [dict get $where column] [dict get $where endColumn]] {2 5 12} \
        "return mismatch covers the offending expression on its own source line"
    check {distinct .id = int
fn .id($value: int) -> .id => $value} RETURN_TYPE "expression bodies keep nominal return checks"
    check {fn .bad() -> int => 1 return 2} E_PARSE_EXPECTED "a second statement cannot follow the expression"
    check {fn .bad() -> int =>} E_PARSE_EXPECTED "the arrow requires an expression"
    check {fn .bad() -> int => return 1} E_PARSE_EXPECTED "return is a statement"
    check {fn .bad() -> int { 1 }} MISSING_RETURN "a block still requires an explicit return"
    check {fn .bad() -> unit { unit }} MISSING_RETURN "unit blocks also require an explicit return"
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
    expressionBodies
    puts "application compiler semantics: $count assertions passed"
}
