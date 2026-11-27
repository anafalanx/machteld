package require machteld

lappend auto_path [file join [file dirname [file dirname [file normalize [info script]]]] \
    packages application-compiler]
package require application-compiler 0.1

namespace eval ::decimalTest {variable count 0}
proc ::decimalTest::equal {actual expected label} {
    variable count
    if {$actual ne $expected} {error "$label: expected [list $expected], got [list $actual]"}
    incr count
}
proc ::decimalTest::typedProblem {result label} {
    lassign $result tag value
    equal $tag err "$label returns err"
    equal [expr {[dict exists $value message] && [dict get $value message] ne ""}] 1 \
        "$label contains a problem message"
    return $value
}
proc ::decimalTest::codes {source} {
    return [lmap d [::appcompiler::check [dict create sample $source]] {dict get $d code}]
}

namespace eval ::decimalTest {
    set numbers {export fn .sum_ok() -> bool { return 0.1 + 0.2 == 0.3 }
export fn .zero() -> decimal { return -0.000 }
export fn .sum($a: decimal, $b: int) -> decimal { return $a + $b }
export fn .difference($a: int, $b: decimal) -> decimal { return $a - $b }
export fn .negate($a: decimal) -> decimal { return -$a }
export fn .same($a: decimal, $b: int) -> bool { return $a == $b }
export fn .big() -> decimal { return 123456789012345678901234567890.125 * 8 }
export fn .tiny() -> decimal { return 0.00000000000000000001 * 0.00000000000000000001 }
export fn .integers($a: int, $b: int) -> result<decimal,problem> { return $a / $b }
export fn .ratio($a: decimal, $b: decimal) -> result<decimal,problem> { return $a / $b }
export fn .whole($a: int, $b: int) -> result<int,problem> { return quotient($a, $b) }
export fn .rounded($a: decimal, $b: decimal, $places: int, $mode: text) -> result<decimal,problem> {
    return divide_rounded($a, $b, $places, $mode)
}}
    set origin {export fn .scaled($a: int, $b: int) -> result<decimal,problem> {
    $value ::= ($a / $b)?
    return ok($value * 2)
}}
    set caller {import origin
export fn .through($a: int, $b: int) -> result<decimal,problem> {
    return ok(.origin::scaled($a, $b)?)
}}
    set sources [dict create calc $numbers origin $origin caller $caller]
    equal [::appcompiler::check $sources] {} "decimal source checks"
    set built [::appcompiler::compile $sources ::decimalApp]
    namespace eval :: [dict get $built script]
    equal [::decimalApp::calc::sum_ok] 1 "0.1 plus 0.2 equals 0.3 exactly"
    equal [::decimalApp::calc::zero] 0 "negative decimal zero has one spelling"
    equal [::decimalApp::calc::sum 9007199254740992.0100 1] 9007199254740993.01 \
        "mixed addition beyond binary double precision"
    equal [::decimalApp::calc::difference 2 2.01250] -0.0125 "mixed subtraction with a negative result"
    equal [::decimalApp::calc::negate -0.00100] 0.001 "negation of a decimal binding"
    equal [::decimalApp::calc::same 8.000 8] 1 "decimal equality with an integer"
    equal [::decimalApp::calc::same 9007199254740992.0001 9007199254740992] 0 \
        "mixed equality does not round two distinct numbers together"
    equal [::decimalApp::calc::big] 987654312098765431209876543121 "product beyond native words"
    equal [::decimalApp::calc::tiny] "0.[string repeat 0 39]1" "exact product at scale forty"

    foreach {a b expected} {6 15 0.4 1 40 0.025 12 -8 -1.5 -12 -8 1.5 12 6 2 0 3 0} {
        equal [::decimalApp::calc::integers $a $b] [list ok $expected] "exact $a / $b"
    }
    equal [::decimalApp::calc::ratio 0.00090 0.012] {ok 0.075} "different decimal operand scales"
    typedProblem [::decimalApp::calc::integers 1 3] "nonterminating decimal expansion"
    typedProblem [::decimalApp::calc::integers 1 0] "division by zero"
    equal [::decimalApp::caller::through 1 8] {ok 0.25} "propagation unwraps a terminating ratio"
    set failure [typedProblem [::decimalApp::caller::through 1 3] "propagated nonterminating division"]
    set site [dict get $failure origin]
    equal [list [dict get $site module] [dict get $site line]] {origin 2} \
        "propagation keeps the failing expression's source site through its caller"

    foreach {a b expected} {7 3 2 -7 3 -2 7 -3 -2 -7 -3 2 -1 3 0 7 1 7} {
        equal [::decimalApp::calc::whole $a $b] [list ok $expected] "integer quotient $a / $b"
    }
    typedProblem [::decimalApp::calc::whole 7 0] "integer quotient by zero"
    foreach {a b places mode expected} {
        5 2 0 half_even 2       -5 2 0 half_even -2
        7 2 0 half_even 4       -7 2 0 half_even -4
        5 2 0 half_away 3       -5 2 0 half_away -3
        1.245 1 2 half_even 1.24    -1.245 1 2 half_away -1.25
        1.2451 1 2 half_even 1.25   -1.2449 1 2 half_away -1.24
        1 -3 4 half_even -0.3333    1 2 5 half_even 0.5
        9.995 1 2 half_even 10      -0.005 1 2 half_even 0
    } {
        equal [::decimalApp::calc::rounded $a $b $places $mode] [list ok $expected] \
            "round $a / $b to $places places using $mode"
    }
    typedProblem [::decimalApp::calc::rounded 1 2 -1 half_even] "negative rounding places"
    typedProblem [::decimalApp::calc::rounded 1 2 3 typo] "unknown rounding mode"
    typedProblem [::decimalApp::calc::rounded 1 0 2 half_even] "rounded division by zero"
    equal [::decimalApp::calc::rounded 1 8 9999999999999999 half_even] {ok 0.125} \
        "exact result at a very large requested scale"
    set tooLarge [typedProblem [::decimalApp::calc::rounded 1 3 100001 half_even] "unrepresentable rounding request"]
    equal [dict get $tooLarge code] ROUND_SCALE_LIMIT "nonterminating expansion limit"

    set clean [interp create]
    try {
        $clean eval [dict get $built script]
        equal [$clean eval {::decimalApp::calc::rounded 13 8 2 half_even}] {ok 1.62} \
            "generated Tcl includes its decimal implementation in a fresh interpreter"
    } finally {interp delete $clean}

    equal [codes {fn .one() -> int { return 1 }
fn .use() -> unit {
    .one() / 2
    quotient(-1, 3)
    divide_rounded(1, 3, 2, 'half_even')
    return unit
}}] {DISCARDED_RESULT DISCARDED_RESULT DISCARDED_RESULT} "discarded divisions require a handler"
    equal [codes {fn .wrong() -> result<int,problem> { return 4 / 2 }}] RETURN_TYPE \
        "even an exact whole quotient has a decimal success type"
    equal [codes {fn .whole() -> result<int,problem> { return quotient(2.5, 1) }
fn .bad_places() -> result<decimal,problem> { return divide_rounded(1, 2, 1.5, 'half_even') }
fn .bad_mode() -> result<decimal,problem> { return divide_rounded(1, 2, 1, true) }}] \
        {ARGUMENT_TYPE ARGUMENT_TYPE ARGUMENT_TYPE} "quotient operands, places and mode are type-checked"
    puts "application compiler decimal: $count assertions passed"
}
