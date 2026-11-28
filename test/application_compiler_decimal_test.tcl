package require machteld

set root [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $root packages application-compiler compiler.tcl]

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
proc ::decimalTest::posting {} {return $::decimalTest::externalValue}

namespace eval ::decimalTest {
    set numbers {export fn .sum_ok() -> bool { return 0.1 + 0.2 == 0.3 }
export fn .zero() -> decimal { return -0.000 }
export fn .amount($value: decimal) -> decimal => $value
export fn .sum($a: decimal, $b: int) -> decimal { return $a + $b }
extern fn .posting() -> decimal = ['::decimalTest::posting']
export fn .add_posting($a: decimal) -> decimal { return $a + .posting() }
export fn .difference($a: int, $b: decimal) -> decimal { return $a - $b }
export fn .negate($a: decimal) -> decimal { return -$a }
export fn .same($a: decimal, $b: int) -> bool { return $a == $b }
export fn .big() -> decimal { return 123456789012345678901234567890.125 * 8 }
export fn .tiny() -> decimal { return 0.00000000000000000001 * 0.00000000000000000001 }
export fn .add_decimals($a: decimal, $b: decimal) -> decimal => $a + $b
export fn .multiply_decimals($a: decimal, $b: decimal) -> decimal => $a * $b
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
    equal [::decimalApp::calc::add_decimals 99999999999999999.9 99999999999999999.9] 199999999999999999.8 \
        "a fractional sum can have a 19-digit coefficient"
    equal [::decimalApp::calc::multiply_decimals 99999999999999999.9 0.9] 89999999999999999.91 \
        "a wide intermediate preserves every product digit"
    equal [::decimalApp::calc::add_decimals -1.125 1.125] 0 "fractional cancellation produces canonical zero"
    equal [::decimalApp::calc::multiply_decimals -0.04 0.25] -0.01 "negative product drops trailing zeroes"
    set tinyFraction "0.[string repeat 0 61]1"
    equal [::decimalApp::calc::multiply_decimals $tinyFraction $tinyFraction] "0.[string repeat 0 123]1" \
        "two short coefficients can produce 124 fractional places"
    set retained [::machteld::json decode -typed {1.125}]
    equal [::decimalApp::calc::add_decimals $retained 2.875] 4 "borrowed native number in a fractional sum"
    equal [::machteld::json type $retained] number "fractional arithmetic retains the incoming native handle"

    foreach {input expected} {
        +000 0  -000.000 0  +0000.00890 0.0089  -0000.00980 -0.0098
        +00100.000 100  -01000 -1000  00080.0090 80.009
    } {
        equal [::decimalApp::calc::sum $input 0] $expected "normalize decimal $input before arithmetic"
    }
    foreach {wire expected} {17 17 -0.15400 -0.154} {
        set node [::machteld::json decode -typed $wire]
        set amount [::decimalApp::calc::amount $node]
        equal $amount $expected "decimal text from a borrowed JSON number"
        equal [catch {::machteld::json type $amount}] 1 "returned decimal is independent text"
        equal [::machteld::json type $node] number "public admission preserves borrowed JSON number"
    }
    set padded "-[string repeat 0 24000].[string repeat 0 24000]1[string repeat 0 24000]"
    equal [::decimalApp::calc::amount $padded] "-0.[string repeat 0 24000]1" \
        "fixed point has arbitrary precision in both input and result"
    set cached 010
    expr {$cached + 0}
    equal [::decimalApp::calc::amount $cached] 10 "decimal admission uses retained spelling"
    set nullText [::machteld::json unwrap [::machteld::json decode -typed {"17\u0000tail"}]]
    foreach value [list $nullText [binary decode hex 31370078]] {
        equal [catch {::decimalApp::calc::amount $value} msg opts] 1 "reject embedded NUL"
        equal [dict get $opts -errorcode] {APPCOMPILER ARGUMENT TYPE} "embedded NUL error code"
    }
    set nines [string repeat 9 300]
    set externalValue "+000$nines.990"
    equal [::decimalApp::calc::add_posting 0.01] "1[string repeat 0 300]" \
        "addition carries across 300 digits after validating an extern result"
    equal [::decimalApp::calc::add_posting "-$nines.99"] 0 "opposite large amounts cancel"
    set externalValue -000.00890
    equal [::decimalApp::calc::add_posting 0.0001] -0.0088 "negative fractional extern in base ten"
    foreach invalid [list {} 1e2 1.0E-2 0x10 1,25 1. .5 NaN Inf "1\n" "1\u00002" "\u0661.2"] {
        equal [catch {::decimalApp::calc::sum $invalid 0} message options] 1 \
            "reject malformed decimal at the public parameter"
        equal [dict get $options -errorcode] {APPCOMPILER ARGUMENT TYPE} "decimal parameter error code"
        set externalValue $invalid
        equal [catch {::decimalApp::calc::add_posting 0.01} message options] 1 \
            "reject malformed extern result before arithmetic"
        equal [dict get $options -errorcode] {APPCOMPILER EXTERN RESULT} "decimal extern result error code"
        equal [dict get $options -appcompilerlocation module] calc "decimal extern declaration location"
    }

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
        1 7 20 half_even 0.14285714285714285714
        0.9999999999999999995 1 18 half_even 1
        12.25 2 2 half_even 6.12
        12.25 2 +002 half_away 6.13
        -100 1.21 2 half_even -82.64
    } {
        equal [::decimalApp::calc::rounded $a $b $places $mode] [list ok $expected] \
            "round $a / $b to $places places using $mode"
    }
    # Both numbers and constructed strings can cross the Tcl application boundary.
    foreach {a places type} {0.5 2 string -0.75 0 string 1.005 1 int} {
        set value [lindex [::decimalApp::calc::rounded $a 1 $places half_even] 1]
        equal [string match "value is a $type *" [tcl::unsupported::representation $value]] 1 \
            "rounded result retains its Tcl representation for $a at $places places"
    }
    # A Tcl read trace can replace an already checked decimal operand.
    foreach {a b firstFailure} {1e1 1 {10.0 % 1} 2 bogus {2 % "bogus"}} {
        set code [catch {::decimalApp::@rt::decimal::rounded $a $b 2 half_even} message options]
        set expected [catch {expr $firstFailure} original details]
        equal [list $code $message [dict get $options -errorcode]] \
            [list $expected $original [dict get $details -errorcode]] "first Tcl error after a decimal read"
    }
    typedProblem [::decimalApp::calc::rounded 1 2 -1 half_even] "negative rounding places"
    typedProblem [::decimalApp::calc::rounded 1 2 3 typo] "unknown rounding mode"
    typedProblem [::decimalApp::calc::rounded 1 0 2 half_even] "rounded division by zero"
    equal [::decimalApp::calc::rounded 1 8 9999999999999999 half_even] {ok 0.125} \
        "exact result at a very large requested scale"
    set tooLarge [typedProblem [::decimalApp::calc::rounded 1 3 100001 half_even] "unrepresentable rounding request"]
    equal [dict get $tooLarge code] ROUND_SCALE_LIMIT "nonterminating expansion limit"
    set tiny "0.[string repeat 0 9999]1"
    equal [::decimalApp::calc::rounded $tiny 1 0 half_even] {ok 0} "small value rounded to whole units"

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
